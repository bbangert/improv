defmodule Improv.Protocol do
  @moduledoc """
  Pure wire codec for the [Improv Wi-Fi BLE protocol](https://www.improv-wifi.com/ble/).

  No D-Bus, no processes — every byte the GATT server reads or notifies is built
  and parsed here, so the protocol is 100% host-testable. Higher layers
  (`Improv` and its GATT server) only move opaque binaries.

  ## Wire format (locked against improv-wifi.com/ble + improv-wifi/sdk-js)

  The RPC command/result characteristics carry framed packets:

      [command_id] [data_length] [data … data_length bytes] [checksum]

  `checksum` is the low byte of the sum of every preceding byte in the frame
  (command, length, and all data bytes). The current-state, error-state and
  capabilities characteristics each carry a single bare byte (no framing).

  ### Submit Wi-Fi (`0x01`) data payload

      [ssid_len] [ssid …] [pwd_len] [pwd …]

  Open networks send `pwd_len = 0`.

  ### Identify (`0x02`) / Device Info (`0x03`)

  Both carry no data (`[cmd][0x00][cs]`). Identify has **no RPC result** — the
  device just does something physically observable. Device Info replies with one
  RPC result carrying four length-prefixed strings: firmware name, firmware
  version, hardware variant, device name.

  ### Request scanned networks (`0x04`)

  Command has no data (`[0x04][0x00][cs]`). The reply is sent as **one RPC-result
  notification per network**, each carrying three strings `[ssid, rssi, auth]`,
  followed by a final **empty** result (`data_len 0`) that terminates the list.

  ## Capabilities

  The capabilities byte is derived from what the host configures (see
  `capabilities/1`): bit2 (`0x04`, scan-wifi) is always set — the command is
  built in, and it's what makes improv-wifi.com show the network dropdown.
  bit0 (`0x01`) is set iff an identify callback is configured, bit1 (`0x02`)
  iff device-info strings are provided. bit3 (hostname) is unsupported.
  """

  import Bitwise, only: [band: 2, bor: 2]

  # --- Service / characteristic UUIDs (full 128-bit) --------------------------

  @service_uuid "00467768-6228-2272-4663-277478268000"
  @uuid_current_state "00467768-6228-2272-4663-277478268001"
  @uuid_error_state "00467768-6228-2272-4663-277478268002"
  @uuid_rpc_command "00467768-6228-2272-4663-277478268003"
  @uuid_rpc_result "00467768-6228-2272-4663-277478268004"
  @uuid_capabilities "00467768-6228-2272-4663-277478268005"

  # --- Command IDs -------------------------------------------------------------

  @cmd_submit_wifi 0x01
  @cmd_identify 0x02
  @cmd_device_info 0x03
  @cmd_request_networks 0x04

  # --- Current-state enum -----------------------------------------------------

  @states %{
    authorization_required: 0x01,
    authorized: 0x02,
    provisioning: 0x03,
    provisioned: 0x04
  }

  # --- Error-state enum -------------------------------------------------------

  @errors %{
    none: 0x00,
    invalid_rpc: 0x01,
    unknown_command: 0x02,
    unable_to_connect: 0x03,
    not_authorized: 0x04,
    unknown: 0xFF
  }

  # --- Capabilities bitfield --------------------------------------------------

  @cap_identify 0x01
  @cap_device_info 0x02
  @cap_scan 0x04

  @typedoc "Decoded inbound RPC command."
  @type command ::
          {:submit_wifi, ssid :: binary(), password :: binary()}
          | {:identify}
          | {:device_info}
          | {:request_wifi_networks}

  @typedoc "Reasons a command frame is rejected."
  @type decode_error :: {:error, :bad_checksum | :unknown_command | :invalid}

  @doc "The Improv primary service UUID."
  @spec service_uuid() :: String.t()
  def service_uuid, do: @service_uuid

  @doc """
  Map of the five characteristic roles to their UUIDs:
  `:current_state`, `:error_state`, `:rpc_command`, `:rpc_result`, `:capabilities`.
  """
  @spec characteristic_uuids() :: %{atom() => String.t()}
  def characteristic_uuids do
    %{
      current_state: @uuid_current_state,
      error_state: @uuid_error_state,
      rpc_command: @uuid_rpc_command,
      rpc_result: @uuid_rpc_result,
      capabilities: @uuid_capabilities
    }
  end

  @doc """
  Capabilities characteristic value (single byte), derived from what the host
  configures: bit2 (scan-wifi) is always set — the command is built in;
  bit0 iff `identify?: true`; bit1 iff `device_info?: true`. Pure.

  The advertisement's ServiceData capabilities byte MUST carry this same
  derived value — derive once and share (the supervisor does this).
  """
  @spec capabilities(keyword()) :: binary()
  def capabilities(opts \\ []) do
    caps =
      @cap_scan
      |> add_cap(@cap_identify, Keyword.get(opts, :identify?, false))
      |> add_cap(@cap_device_info, Keyword.get(opts, :device_info?, false))

    <<caps>>
  end

  defp add_cap(byte, bit, true), do: bor(byte, bit)
  defp add_cap(byte, _bit, false), do: byte

  @doc """
  Decode an inbound RPC-command frame written to the rpc-command characteristic.

  Validates structure and checksum before dispatching. Returns the decoded
  `t:command/0`, or `{:error, reason}`:

    * `:invalid` — too short, length field inconsistent, or a malformed
      submit-wifi payload (maps to Improv error `invalid RPC packet`).
    * `:bad_checksum` — checksum mismatch (also `invalid RPC packet`).
    * `:unknown_command` — well-formed frame for a command we don't implement.
  """
  @spec decode_command(binary()) :: command() | decode_error()
  def decode_command(<<cmd, data_len, rest::binary>>)
      when byte_size(rest) == data_len + 1 do
    <<data::binary-size(^data_len), checksum>> = rest

    if checksum == frame_checksum(cmd, data_len, data) do
      decode_payload(cmd, data)
    else
      {:error, :bad_checksum}
    end
  end

  def decode_command(_), do: {:error, :invalid}

  defp decode_payload(@cmd_submit_wifi, data), do: decode_submit_wifi(data)
  # identify / device-info / request-networks must carry no data; anything
  # else is malformed.
  defp decode_payload(@cmd_identify, <<>>), do: {:identify}
  defp decode_payload(@cmd_identify, _), do: {:error, :invalid}
  defp decode_payload(@cmd_device_info, <<>>), do: {:device_info}
  defp decode_payload(@cmd_device_info, _), do: {:error, :invalid}
  defp decode_payload(@cmd_request_networks, <<>>), do: {:request_wifi_networks}
  defp decode_payload(@cmd_request_networks, _), do: {:error, :invalid}
  defp decode_payload(_cmd, _data), do: {:error, :unknown_command}

  defp decode_submit_wifi(
         <<ssid_len, ssid::binary-size(ssid_len), pwd_len, pwd::binary-size(pwd_len)>>
       ) do
    {:submit_wifi, ssid, pwd}
  end

  defp decode_submit_wifi(_), do: {:error, :invalid}

  @doc "Encode a current-state value (single byte, no framing)."
  @spec encode_state(atom()) :: binary()
  def encode_state(state) when is_map_key(@states, state), do: <<@states[state]>>

  @doc "Encode an error-state value (single byte, no framing)."
  @spec encode_error(atom()) :: binary()
  def encode_error(error) when is_map_key(@errors, error), do: <<@errors[error]>>

  @doc """
  Encode a framed RPC result for `command_id` carrying `strings`.

  Each string is length-prefixed; an empty list yields a bare `[cmd][0][cs]`
  frame (the terminator for a scan, or a result with no payload).
  """
  @spec encode_rpc_result(byte(), [binary()]) :: binary()
  def encode_rpc_result(command_id, strings)
      when is_integer(command_id) and is_list(strings) do
    data = Enum.map_join(strings, "", fn s -> <<byte_size(s), s::binary>> end)
    frame(command_id, data)
  end

  @doc """
  Encode one Wi-Fi network entry as a scan RPC-result notification:
  three strings `[ssid, rssi, auth]` where `rssi` is rendered as a signed
  decimal and `secured` becomes `"YES"`/`"NO"`. Terminate the list with
  `encode_rpc_result(0x04, [])`.
  """
  @spec encode_wifi_network_entry(binary(), integer(), boolean()) :: binary()
  def encode_wifi_network_entry(ssid, rssi, secured)
      when is_binary(ssid) and is_integer(rssi) and is_boolean(secured) do
    auth = if secured, do: "YES", else: "NO"
    encode_rpc_result(@cmd_request_networks, [ssid, Integer.to_string(rssi), auth])
  end

  @doc "Command id for a request-scanned-networks result frame."
  @spec request_networks_command() :: byte()
  def request_networks_command, do: @cmd_request_networks

  @doc "Command id for a submit-wifi result frame."
  @spec submit_wifi_command() :: byte()
  def submit_wifi_command, do: @cmd_submit_wifi

  @doc "Command id of the identify command."
  @spec identify_command() :: byte()
  def identify_command, do: @cmd_identify

  @doc "Command id for a device-info result frame."
  @spec device_info_command() :: byte()
  def device_info_command, do: @cmd_device_info

  @doc """
  Checksum of a complete frame *without* its trailing checksum byte:
  the low byte of the sum of every byte. Exposed for framing helpers/tests.
  """
  @spec checksum(binary()) :: byte()
  def checksum(bin) when is_binary(bin) do
    bin |> :binary.bin_to_list() |> Enum.sum() |> band(0xFF)
  end

  defp frame(command_id, data) do
    body = <<command_id, byte_size(data), data::binary>>
    <<body::binary, checksum(body)>>
  end

  defp frame_checksum(cmd, data_len, data), do: checksum(<<cmd, data_len, data::binary>>)
end
