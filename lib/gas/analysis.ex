defmodule Gas.Analysis do
  @moduledoc """
  What a parsed template reads and renders, without running it.

  A caller holding data that a template only partly looks at can use this to
  find the part, and so decide that two renders it cannot tell apart will agree.
  """

  alias Gas.AccessLiteral
  alias Gas.Literal
  alias Gas.Tags.RenderTag
  alias Gas.Variable

  @type path :: [binary | integer]

  @doc """
  Every variable path the tree reads.

  A path stops at the first access the tree does not fix, so `a.b[k]` reads
  `["a", "b"]`: which of `b`'s keys it wants is not known here, and a caller
  narrowing on the path set must treat the whole of `b` as read. A name bound to
  another read carries that read with it — `{% assign x = a.b %}{{ x.c }}` reads
  `["a", "b"]` as well as `["x", "c"]` — so a path set can be trusted without
  following assignment.
  """
  @spec reads(term) :: MapSet.t(path)
  def reads(tree), do: read_paths(tree, MapSet.new())

  @doc """
  Templates the tree renders, `:computed` standing for a name it builds itself.
  """
  @spec render_targets(term) :: MapSet.t(binary | :computed)
  def render_targets(tree), do: targets(tree, MapSet.new())

  defp read_paths(%Variable{identifier: identifier, accesses: accesses} = variable, acc) do
    variable |> Map.from_struct() |> read_paths(put_path(acc, identifier, accesses))
  end

  defp read_paths(list, acc) when is_list(list), do: Enum.reduce(list, acc, &read_paths/2)

  defp read_paths(%{__struct__: _} = struct, acc),
    do: struct |> Map.from_struct() |> read_paths(acc)

  defp read_paths(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> read_paths(acc)

  defp read_paths(map, acc) when is_map(map),
    do: map |> Map.values() |> Enum.reduce(acc, &read_paths/2)

  defp read_paths(_other, acc), do: acc

  defp put_path(acc, identifier, accesses) do
    fixed =
      accesses |> Enum.take_while(&match?(%AccessLiteral{}, &1)) |> Enum.map(& &1.value)

    case if(identifier, do: [identifier | fixed], else: fixed) do
      [] -> acc
      path -> MapSet.put(acc, path)
    end
  end

  defp targets(%RenderTag{template: %Literal{value: name, interp_ast: nil}} = node, acc)
       when is_binary(name),
       do: node |> Map.from_struct() |> targets(MapSet.put(acc, name))

  defp targets(%RenderTag{} = node, acc),
    do: node |> Map.from_struct() |> targets(MapSet.put(acc, :computed))

  defp targets(list, acc) when is_list(list), do: Enum.reduce(list, acc, &targets/2)

  defp targets(%{__struct__: _} = struct, acc), do: struct |> Map.from_struct() |> targets(acc)

  defp targets(tuple, acc) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> targets(acc)

  defp targets(map, acc) when is_map(map),
    do: map |> Map.values() |> Enum.reduce(acc, &targets/2)

  defp targets(_other, acc), do: acc
end
