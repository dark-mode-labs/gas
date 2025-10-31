defmodule Solid.Caching.EtsCache do
  @behaviour Solid.Caching

  @cache :liquid_snippet_cache

  defp ensure_cache do
    case :ets.whereis(@cache) do
      :undefined -> :ets.new(@cache, [:named_table, :public, read_concurrency: true])
      _ -> :ok
    end
  end

  @impl true
  def get(cache_key) do
    ensure_cache()

    case :ets.lookup(@cache, cache_key) do
      [] ->
        {:error, :not_found}

      [{^cache_key, entry}] ->
        {:ok, entry}
    end
  end

  @impl true
  def put(cache_key, value) do
    ensure_cache()

    :ets.insert(@cache, {cache_key, value})

    :ok
  end
end
