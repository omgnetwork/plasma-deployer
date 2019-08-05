defmodule PlasmaDeployer.Router do
  use Plug.Router

  plug(Plug.Logger)
  plug(Plug.Static, from: ".", at: "/")
  plug(:match)
  plug(:dispatch)

  get "/*path" do
    send_resp(conn, 200, Jason.encode!(Agent.get(PlasmaDeployer.Deploy, & &1)))
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
