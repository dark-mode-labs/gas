defmodule Gas.Compiler.TextMerge do
  @moduledoc """
  Compile-time pass that concatenates consecutive `%Gas.Text{}` nodes
  inside any parse-tree list (template body, tag body, capture body,
  for-loop body, etc). Reduces per-render `Enum.reduce` iterations and
  iolist cons operations by collapsing whitespace-heavy parse output
  into single text nodes per text run.
  """

  alias Gas.{Template, Text}

  @spec run(Template.t()) :: Template.t()
  def run(%Template{parsed_template: tree} = template) do
    %{template | parsed_template: walk(tree)}
  end

  defp walk(list) when is_list(list) do
    list
    |> Enum.map(&walk/1)
    |> collapse([])
  end

  defp walk(%_struct{} = s) do
    s
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, walk(v)} end)
    |> then(&struct(s.__struct__, &1))
  end

  defp walk(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, walk(v)} end)
  end

  defp walk(tuple) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&walk/1)
    |> List.to_tuple()
  end

  defp walk(other), do: other

  defp collapse([], acc), do: Enum.reverse(acc)

  defp collapse([%Text{text: a} | rest], [%Text{text: b, loc: loc} | acc]) do
    collapse(rest, [%Text{text: b <> a, loc: loc} | acc])
  end

  defp collapse([node | rest], acc), do: collapse(rest, [node | acc])
end
