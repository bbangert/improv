defmodule Improv.Tasks do
  # Shared fire-and-forget task runner for the Improv processes (manager,
  # GattServer, Advert). Not part of the public API.
  @moduledoc false

  require Logger

  @doc """
  Run `fun` off the caller's GenServer loop, under `sup` (a `Task.Supervisor`
  name) when it's alive (production), else a bare `Task` (host tests, where
  the supervisor isn't started). Falls back to `Task.start` if the supervisor
  refuses (e.g. `max_restarts`) so work is never silently dropped — that
  production case is logged under `owner`: a restart-throttled supervisor
  spawning unsupervised work is exactly when crash visibility matters most.
  No log when the supervisor simply isn't registered.

  Returns `{:ok, pid}` so callers can monitor the spawned task.
  """
  @spec run(atom(), (-> any()), String.t()) :: {:ok, pid()}
  def run(sup, fun, owner) do
    case Process.whereis(sup) do
      nil ->
        Task.start(fun)

      _pid ->
        case Task.Supervisor.start_child(sup, fun) do
          {:ok, pid} ->
            {:ok, pid}

          error ->
            Logger.warning(
              "#{owner}: Task.Supervisor #{inspect(sup)} refused (#{inspect(error)}); " <>
                "running unsupervised"
            )

            Task.start(fun)
        end
    end
  end
end
