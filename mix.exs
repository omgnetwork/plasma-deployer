defmodule PlasmaDeployer.Mixfile do
  use Mix.Project

  def project do
    [
      app: :plasma_deployer,
      version: "1.0.2",
      elixir: "~> 1.5",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application do
    [mod: {PlasmaDeployer, []}]
  end

  defp deps do
    [
      {:plug, "~> 1.0"},
      {:plug_cowboy, "~> 2.0"},
      {:ethereumex, "~> 0.5.4"}
    ]
  end

  defp escript do
    [main_module: PlasmaDeployer]
  end
end
