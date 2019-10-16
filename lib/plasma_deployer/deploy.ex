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

      # Infura specifics
      IO.puts(file, "DEPLOYER_PRIVATEKEY=#{System.get_env("DEPLOYER_PRIVATEKEY")}")
      IO.puts(file, "AUTHORITY_PRIVATEKEY=#{System.get_env("AUTHORITY_PRIVATEKEY")}")
      IO.puts(file, "INFURA_URL=#{System.get_env("INFURA_URL")}")
      IO.puts(file, "INFURA_API_KEY=#{System.get_env("INFURA_API_KEY")}")
    end)

    result_text = do_deploy(5, opts)

    [_, plasma_framework_tx_hash] = String.split(result_text, ["plasma_framework_tx_hash"], trim: true)
    plasma_framework_tx_hash = hd(String.split(plasma_framework_tx_hash, ["\":\""], trim: true))
    [plasma_framework_tx_hash, _, _] = String.split(plasma_framework_tx_hash, ["\""], trim: true)

    #middle four parse the same way, first and last occurance is different
    [_, plasma_framework] = String.split(result_text, ["\"plasma_framework\""], trim: true)
    plasma_framework = hd(String.split(plasma_framework, ["\":\""], trim: true))
    plasma_framework = Enum.at(String.split(plasma_framework, ["\""], trim: true), 1)

    [_, eth_vault] = String.split(result_text, ["\"eth_vault\""], trim: true)
    eth_vault = hd(String.split(eth_vault, ["\":\""], trim: true))
    eth_vault = Enum.at(String.split(eth_vault, ["\""], trim: true), 1)

    [_, erc20_vault] = String.split(result_text, ["\"erc20_vault\""], trim: true)
    erc20_vault = hd(String.split(erc20_vault, ["\":\""], trim: true))
    erc20_vault = Enum.at(String.split(erc20_vault, ["\""], trim: true), 1)

    [_, payment_exit_game] = String.split(result_text, ["\"payment_exit_game\""], trim: true)
    payment_exit_game = hd(String.split(payment_exit_game, ["\":\""], trim: true))
    payment_exit_game = Enum.at(String.split(payment_exit_game, ["\""], trim: true), 1)

    [_, authority_address] = String.split(result_text, ["\"payment_exit_game\""], trim: true)
    authority_address = tl(String.split(authority_address, ["\":\""], trim: true))
    [authority_address, _] = String.split(Enum.at(authority_address, 0), ["\""], trim: true)

    values = %{plasma_framework_tx_hash: plasma_framework_tx_hash, plasma_framework: plasma_framework, eth_vault: eth_vault,
    erc20_vault: erc20_vault, payment_exit_game: payment_exit_game, authority_address: authority_address}
    Agent.start_link(fn -> values end, name: __MODULE__)
  end

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
    authority_addr = System.get_env("DEPLOYER_ADDRESS") || raise("DEPLOYER_ADDRESS is required for infura deployment.")
    deployer_addr = System.get_env("AUTHORITY_ADDRESS") || raise("AUTHORITY_ADDRESS is required for infura deployment.")
    {:ok, authority_addr, deployer_addr}
  end

  defp parse_client_type(nil), do: :geth
  defp parse_client_type("geth"), do: :geth
  defp parse_client_type("parity"), do: :parity
  defp parse_client_type("infura"), do: :infura
  defp parse_client_type(""), do: parse_client_type(nil)
  defp parse_client_type(_), do: raise("Unrecognized client type provided.")

  defp do_deploy(0, _opts), do: {:error, :deploy}
  defp do_deploy(index, opts) do
    network = truffle_network_by_client(opts[:client_type])
    {result_text, _} = result = System.cmd("npx", ["truffle", "migrate", "--network", network, "--reset"])
    :ok = Enum.each(String.split(result_text, "\n"), &Logger.info(&1))
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
