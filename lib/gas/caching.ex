defmodule Gas.Caching do
  @callback get(key :: term) :: {:ok, Gas.Template.t()} | {:error, :not_found}

  @callback put(key :: term, Gas.Template.t()) :: :ok | {:error, term}
end
