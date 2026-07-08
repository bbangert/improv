defmodule Improv.ProtocolTest do
  use ExUnit.Case, async: true

  alias Improv.Protocol

  import Bitwise, only: [band: 2]

  # Build a frame [cmd][len][data][checksum] with a *correct* checksum, computed
  # independently of the production code so the round-trip genuinely cross-checks.
  defp framed(cmd, data) do
    body = <<cmd, byte_size(data), data::binary>>
    <<body::binary, sum(body)>>
  end

  defp sum(bin), do: bin |> :binary.bin_to_list() |> Enum.sum() |> band(0xFF)

  defp submit_data(ssid, pwd),
    do: <<byte_size(ssid), ssid::binary, byte_size(pwd), pwd::binary>>

  describe "decode_command/1 — submit-wifi (0x01)" do
    test "decodes ssid + password" do
      frame = framed(0x01, submit_data("MyNet", "secret12"))
      assert Protocol.decode_command(frame) == {:submit_wifi, "MyNet", "secret12"}
    end

    test "decodes an open network (empty password)" do
      frame = framed(0x01, submit_data("OpenAP", ""))
      assert Protocol.decode_command(frame) == {:submit_wifi, "OpenAP", ""}
    end

    test "decodes an empty SSID structurally (range validation is a higher layer)" do
      frame = framed(0x01, submit_data("", "pw"))
      assert Protocol.decode_command(frame) == {:submit_wifi, "", "pw"}
    end

    test "decodes a 32-byte (max) SSID" do
      ssid = String.duplicate("a", 32)
      frame = framed(0x01, submit_data(ssid, "pw"))
      assert Protocol.decode_command(frame) == {:submit_wifi, ssid, "pw"}
    end

    test "decodes a multi-byte UTF-8 SSID by its byte length" do
      ssid = "café-📶"
      frame = framed(0x01, submit_data(ssid, "héllo"))
      assert Protocol.decode_command(frame) == {:submit_wifi, ssid, "héllo"}
    end

    test "rejects a submit payload whose inner lengths don't consume the data" do
      # ssid_len says 5 but only 3 bytes follow before pwd_len.
      bad = <<5, "abc", 0>>
      frame = framed(0x01, bad)
      assert Protocol.decode_command(frame) == {:error, :invalid}
    end
  end

  describe "decode_command/1 — request-networks (0x04)" do
    test "decodes the no-data request" do
      assert Protocol.decode_command(framed(0x04, <<>>)) == {:request_wifi_networks}
    end

    test "rejects a request-networks frame that carries data" do
      assert Protocol.decode_command(framed(0x04, <<0x00>>)) == {:error, :invalid}
    end
  end

  describe "decode_command/1 — framing errors" do
    test "bad checksum" do
      good = framed(0x01, submit_data("MyNet", "pw"))
      # Flip the trailing checksum byte.
      head_len = byte_size(good) - 1
      <<rest::binary-size(^head_len), cs>> = good
      corrupt = <<rest::binary, band(cs + 1, 0xFF)>>
      assert Protocol.decode_command(corrupt) == {:error, :bad_checksum}
    end

    test "truncated frame (fewer than 3 bytes)" do
      assert Protocol.decode_command(<<>>) == {:error, :invalid}
      assert Protocol.decode_command(<<0x01>>) == {:error, :invalid}
      assert Protocol.decode_command(<<0x01, 0x00>>) == {:error, :invalid}
    end

    test "length field inconsistent with the frame size" do
      # data_len = 4 but only 1 data byte + checksum present.
      assert Protocol.decode_command(<<0x01, 0x04, 0xAA, 0x00>>) == {:error, :invalid}
      # data_len = 0 but extra trailing bytes present.
      assert Protocol.decode_command(<<0x04, 0x00, 0x00, 0x00>>) == {:error, :invalid}
    end

    test "unknown but well-formed command" do
      # 0x08 is unassigned; checksum is valid.
      assert Protocol.decode_command(framed(0x08, <<>>)) == {:error, :unknown_command}
    end
  end

  describe "decode_command/1 — identify (0x02) / device-info (0x03)" do
    test "decodes the no-data commands" do
      assert Protocol.decode_command(framed(0x02, <<>>)) == {:identify}
      assert Protocol.decode_command(framed(0x03, <<>>)) == {:device_info}
    end

    test "rejects frames that carry data" do
      assert Protocol.decode_command(framed(0x02, <<1>>)) == {:error, :invalid}
      assert Protocol.decode_command(framed(0x03, <<1, 2>>)) == {:error, :invalid}
    end

    test "command id accessors match the wire ids" do
      assert Protocol.identify_command() == 0x02
      assert Protocol.device_info_command() == 0x03
    end
  end

  describe "encode_state/1 + encode_error/1 + capabilities/0" do
    test "state bytes" do
      assert Protocol.encode_state(:authorization_required) == <<0x01>>
      assert Protocol.encode_state(:authorized) == <<0x02>>
      assert Protocol.encode_state(:provisioning) == <<0x03>>
      assert Protocol.encode_state(:provisioned) == <<0x04>>
    end

    test "error bytes" do
      assert Protocol.encode_error(:none) == <<0x00>>
      assert Protocol.encode_error(:invalid_rpc) == <<0x01>>
      assert Protocol.encode_error(:unknown_command) == <<0x02>>
      assert Protocol.encode_error(:unable_to_connect) == <<0x03>>
      assert Protocol.encode_error(:not_authorized) == <<0x04>>
      assert Protocol.encode_error(:unknown) == <<0xFF>>
    end

    test "capabilities always advertises scan-wifi (bit 2)" do
      assert Protocol.capabilities() == <<0x04>>
      assert Protocol.capabilities([]) == <<0x04>>
    end

    test "capabilities derives identify (bit 0) and device-info (bit 1)" do
      assert Protocol.capabilities(identify?: true) == <<0x05>>
      assert Protocol.capabilities(device_info?: true) == <<0x06>>
      assert Protocol.capabilities(identify?: true, device_info?: true) == <<0x07>>
      assert Protocol.capabilities(identify?: false, device_info?: false) == <<0x04>>
    end
  end

  describe "encode_rpc_result/2" do
    test "encodes a submit-wifi success result carrying a redirect URL" do
      url = "http://192.168.1.50"
      frame = Protocol.encode_rpc_result(0x01, [url])

      expected_data = <<byte_size(url), url::binary>>
      assert frame == framed(0x01, expected_data)
      # And it round-trips through the checksum check shape used by clients.
      assert <<0x01, len, body::binary-size(len), _cs>> = frame
      assert body == expected_data
    end

    test "an empty string list yields a bare terminator frame" do
      assert Protocol.encode_rpc_result(0x04, []) == framed(0x04, <<>>)
    end
  end

  describe "encode_wifi_network_entry/3" do
    test "encodes ssid / rssi / secured as three strings under command 0x04" do
      frame = Protocol.encode_wifi_network_entry("HomeWiFi", -42, true)

      data =
        <<byte_size("HomeWiFi"), "HomeWiFi", byte_size("-42"), "-42", byte_size("YES"), "YES">>

      assert frame == framed(0x04, data)
    end

    test "open network renders auth NO" do
      frame = Protocol.encode_wifi_network_entry("Guest", -70, false)
      data = <<5, "Guest", 3, "-70", 2, "NO">>
      assert frame == framed(0x04, data)
    end
  end

  describe "checksum/1" do
    test "is the low byte of the sum of all bytes" do
      assert Protocol.checksum(<<0x02, 0x00>>) == 0x02
      assert Protocol.checksum(<<0xFF, 0x02>>) == 0x01
      assert Protocol.checksum(<<>>) == 0x00
    end
  end
end
