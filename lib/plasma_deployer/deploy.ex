defmodule PlasmaDeployer.Deploy do
  require Logger
  @passphrase "ThisIsATestnetPassphrase"
  @one_hundred_eth trunc(:math.pow(10, 18) * 100)
  @about_4_blocks_time 60_000

  def do_it do
    opts = [
      client_type: parse_client_type(System.get_env("CLIENT_TYPE"))
    ]

    {:ok, authority_addr, deployer_addr} = prepare(opts)

    IO.puts(authority_addr)
    IO.puts(deployer_addr)

    File.open!(".env", [:write], fn file ->
      IO.puts(file, "DEPLOYER_ADDRESS=#{deployer_addr}")
      IO.puts(file, "DEPLOYER_PASSPHRASE=\"\"")
      IO.puts(file, "AUTHORITY_ADDRESS=#{authority_addr}")
      IO.puts(file, "AUTHORITY_PASSPHRASE=#{@passphrase}")
      host = System.get_env("ETH_CLIENT_HOST") || "localhost"
      IO.puts(file, "ETH_CLIENT_HOST=#{host}")
      port = System.get_env("ETH_CLIENT_PORT") || 8545
      IO.puts(file, "ETH_CLIENT_PORT=#{port}")
      exit_period_seconds = System.get_env("EXIT_PERIOD_SECONDS") || 600
      IO.puts(file, "MIN_EXIT_PERIOD=#{exit_period_seconds}")

      Enum.each(extra_envs(opts), fn {key, value} ->
        IO.puts(file, "#{key}=#{value}")
      end)
    end)

    file = File.read!(".env")
    IO.inspect file
    do_deploy(5, opts)

    data = File.read!("plasma_framework/build/outputs.json")
    IO.inspect data
    %{plasma_framework_tx_hash: _plasma_framework_tx_hash, plasma_framework: _plasma_framework, eth_vault: _eth_vault,
    erc20_vault: _erc20_vault, payment_exit_game: _payment_exit_game, authority_address: _authority} = values = Jason.decode!(data, keys: :atoms)

    Agent.start_link(fn -> values end, name: __MODULE__)
  end

  defp parse_client_type(nil), do: :geth
  defp parse_client_type("geth"), do: :geth
  defp parse_client_type("parity"), do: :parity
  defp parse_client_type("infura"), do: :infura
  defp parse_client_type(""), do: parse_client_type(nil)
  defp parse_client_type(_), do: exit("Unrecognized client type provided. Supports geth, parity and infura.")

  defp prepare(opts), do: prepare(opts[:client_type], opts)

  defp prepare(:geth, opts) do
    {:ok, authority_addr} = create_and_fund_authority_addr(opts)
    {:ok, deployer_addr} = get_deployer_address(opts)
    {:ok, authority_addr, deployer_addr}
  end

  defp prepare(:parity, opts) do
    {:ok, authority_addr} = create_and_fund_authority_addr(opts)
    {:ok, deployer_addr} = get_deployer_address(opts)
    {:ok, authority_addr, deployer_addr}
  end

  defp prepare(:infura, _opts) do
    authority_addr = System.get_env("AUTHORITY_ADDRESS") || exit("AUTHORITY_ADDRESS is required for infura deployment.")
    deployer_addr = System.get_env("DEPLOYER_ADDRESS") || exit("DEPLOYER_ADDRESS is required for infura deployment.")
    {:ok, authority_addr, deployer_addr}
  end

  defp extra_envs(opts), do: extra_envs(opts[:client_type], opts)

  defp extra_envs(:infura, _opts) do
    [
      {"INFURA_URL", System.get_env("INFURA_URL") || exit("INFURA_URL is required for infura deployment.")},
      {"INFURA_API_KEY", System.get_env("INFURA_API_KEY") || exit("INFURA_API_KEY is required for infura deployment.")},
      {"DEPLOYER_PRIVATEKEY", System.get_env("DEPLOYER_PRIVATEKEY") || exit("DEPLOYER_PRIVATEKEY is required for infura deployment.")},
      {"MAINTAINER_PRIVATEKEY", System.get_env("MAINTAINER_PRIVATEKEY") || exit("MAINTAINER_PRIVATEKEY is required for infura deployment.")},
      {"AUTHORITY_PRIVATEKEY", System.get_env("AUTHORITY_PRIVATEKEY") || exit("AUTHORITY_PRIVATEKEY is required for infura deployment.")},
      {"USE_EXISTING_AUTHORITY_ADDRESS", "true"}
    ]
  end

  defp extra_envs(:geth, _), do: []
  defp extra_envs(:parity, _), do: []
  defp extra_envs(_, _), do: []

  defp do_deploy(0, _opts), do: {:error, :deploy}
  defp do_deploy(index, opts) do
    network = truffle_network_by_client(opts[:client_type])
    {result_text, _} = result = System.cmd("npx", ["truffle", "migrate", "--network", network, "--reset"], cd: "plasma_framework")
    :ok = Enum.each(String.split(result_text, "\n"), &Logger.warn(&1))
    case result do
      {_, 0} -> result_text
      _ -> do_deploy(index - 1, opts)
    end
  end

  defp truffle_network_by_client(:infura), do: "infura"
  defp truffle_network_by_client(_), do: "local"

  def create_and_fund_authority_addr(opts) do
    with {:ok, authority} <-
           Ethereumex.HttpClient.request("personal_newAccount", [@passphrase], url: get_host_from_env()),
         {:ok, _} <- fund_address_from_faucet(authority, opts) do
      {:ok, authority}
    end
  end

  defp get_deployer_address(opts) do
    with {:ok, [addr | _]} <- Ethereumex.HttpClient.eth_accounts(url: get_host_from_env()),
         do: {:ok, Keyword.get(opts, :faucet, addr)}
  end

  def fund_address_from_faucet(account_enc, opts) do
    {:ok, [default_faucet | _]} = Ethereumex.HttpClient.eth_accounts(url: get_host_from_env())
    defaults = [faucet: default_faucet, initial_funds: @one_hundred_eth]

    %{faucet: faucet, initial_funds: initial_funds} =
      defaults
      |> Keyword.merge(opts)
      |> Enum.into(%{})

    unlock_if_possible(account_enc, opts[:client_type])

    params = %{from: faucet, to: account_enc, value: to_hex(initial_funds)}
    {:ok, tx_fund} = send_transaction(params)

    eth_receipt(tx_fund, @about_4_blocks_time)
  end

  def eth_receipt(txhash, timeout \\ 15_000) do
    f = fn ->
      txhash
      |> to_hex()
      |> Ethereumex.HttpClient.eth_get_transaction_receipt(url: get_host_from_env())
      |> case do
        {:ok, receipt} when receipt != nil -> {:ok, receipt}
        _ -> :repeat
      end
    end

    fn -> repeat_until_ok(f) end
    |> Task.async()
    |> Task.await(timeout)
  end

  def repeat_until_ok(f) do
    Process.sleep(100)

    try do
      case f.() do
        {:ok, _} = return -> return
        _ -> repeat_until_ok(f)
      end
    catch
      _something -> repeat_until_ok(f)
      :error, {:badmatch, _} = _error -> repeat_until_ok(f)
    end
  end

  def send_transaction(txmap) do
    {:ok, receipt_enc} = Ethereumex.HttpClient.eth_send_transaction(txmap, url: get_host_from_env())
    {:ok, from_hex(receipt_enc)}
  end

  def to_hex(non_hex)
  def to_hex(raw) when is_binary(raw), do: "0x" <> Base.encode16(raw, case: :lower)
  def to_hex(int) when is_integer(int), do: "0x" <> Integer.to_string(int, 16)

  def from_hex("0x" <> encoded), do: Base.decode16!(encoded, case: :lower)

  defp unlock_if_possible(account_enc, :geth) do
    {:ok, true} =
      Ethereumex.HttpClient.request("personal_unlockAccount", [account_enc, @passphrase, 0], url: get_host_from_env())
  end

  defp unlock_if_possible(_account_enc, :parity) do
    :dont_bother_will_use_personal_sendTransaction
  end

  defp unlock_if_possible(_account_enc, :infura) do
    :dont_bother_will_use_sendRawTransaction
  end

  defp get_host_from_env() do
    host = System.get_env("ETH_CLIENT_HOST") || "localhost"
    port = System.get_env("ETH_CLIENT_PORT") || 8545
    "http://#{host}:#{port}"
  end
end
