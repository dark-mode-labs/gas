defmodule Gas.StandardFilter do
  @moduledoc """
  Standard filters
  """

  alias Gas.Filters.Filter

  import Kernel, except: [abs: 1, ceil: 1, round: 1, floor: 1, apply: 2]

  @function_map Filter.__info__(:functions)
                |> Enum.reduce(%{}, fn
                  {k, v}, acc ->
                    Map.update(acc, to_string(k), %{atom: k, arities: [v]}, fn existing ->
                      %{existing | arities: [v | existing.arities]}
                    end)
                end)

  @spec apply(String.t(), list(), Gas.Parser.Loc.t(), keyword()) ::
          {:ok, any()} | {:error, Exception.t(), any()} | {:error, Exception.t()}
  def apply(filter, args, loc, _opts) do
    apply_filter(filter, args, loc)
  end

  defp apply_filter(func, _args, loc) when not is_map_key(@function_map, func) do
    {:error, %Gas.UndefinedFilterError{loc: loc, filter: func}}
  end

  defp apply_filter(func, args, loc) do
    asked_arity = Enum.count(args)
    %{atom: atom, arities: arities} = @function_map[func]

    if asked_arity in arities do
      try do
        {:ok, Kernel.apply(Filter, atom, args)}
      rescue
        e ->
          {:error,
           %Gas.ArgumentError{
             loc: loc,
             message: "Filter: #{func} #{String.trim(inspect(e))}"
           }}
      end
    else
      {:error,
       %Gas.WrongFilterArityError{
         loc: loc,
         filter: func,
         arity: asked_arity,
         expected_arity: Enum.map_join(arities, "/", &"#{&1}")
       }}
    end
  end
end
