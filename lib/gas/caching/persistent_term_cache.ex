defmodule Gas.Caching.PersistentTermCache do
  @moduledoc """
  Template cache backed by `:persistent_term`. Reads are zero-copy
  reference fetches; writes trigger a global GC, so entries should be
  written once at boot.
  """

  @behaviour Gas.Caching

  @impl true
  def get(cache_key) do
    case :persistent_term.get({__MODULE__, cache_key}, :__miss__) do
      :__miss__ -> {:error, :not_found}
      value -> {:ok, value}
    end
  end

  @impl true
  def put(cache_key, value) do
    :persistent_term.put({__MODULE__, cache_key}, value)
    :ok
  end
end
