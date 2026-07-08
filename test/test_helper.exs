# Broadcast-asserting manager tests need a running PubSub (the lib default is
# nil = no-op); phoenix_pubsub is an optional dep present in the test env.
{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: Improv.TestPubSub}], strategy: :one_for_one)

ExUnit.start()
