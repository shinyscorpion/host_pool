use Mix.Config

config :hackney, pool_handler: HostPool

config :host_pool,
  connection_pool: HostPool.ConnectionPool,
  checkout_timeout: 5_000,
  pool_type: :host,
  limit: 10
