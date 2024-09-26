import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:attempt, :key, :owner]
