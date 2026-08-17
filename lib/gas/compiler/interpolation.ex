defmodule Gas.Compiler.Interpolation do
  @moduledoc """
  Resolves Liquid interpolation at AST entry.

    * `expand/2` — populates `interp_ast` on `Gas.Literal{}` nodes whose
      value contains Liquid syntax. Called from `Gas.precompile/2`.
    * `normalize_vars/2` — replaces binaries inside a vars map with
      `Gas.InterpolatedString{}` sentinels carrying their parsed AST.
  """

  alias Gas.{InterpolatedString, Literal, Template, Text, Variable}

  @spec expand(Template.t(), keyword) :: Template.t()
  def expand(%Template{parsed_template: tree} = template, opts) do
    %{template | parsed_template: walk_tree(tree, opts)}
  end

  defp walk_tree(list, opts) when is_list(list), do: Enum.map(list, &walk_tree(&1, opts))

  defp walk_tree(%Literal{value: value, interp_ast: nil} = lit, opts) when is_binary(value) do
    case parse_if_interpolated(value, opts) do
      nil -> lit
      template -> %{lit | interp_ast: template}
    end
  end

  defp walk_tree(%Variable{} = var, opts) do
    walked =
      var
      |> Map.from_struct()
      |> Enum.map(fn {k, v} -> {k, walk_tree(v, opts)} end)
      |> then(&struct(Variable, &1))

    case Variable.static_keys(walked) do
      nil -> walked
      keys -> %{walked | static_keys: keys}
    end
  end

  defp walk_tree(%_struct{} = s, opts) do
    s
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, walk_tree(v, opts)} end)
    |> then(&struct(s.__struct__, &1))
  end

  defp walk_tree(map, opts) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, walk_tree(v, opts)} end)
  end

  defp walk_tree(tuple, opts) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&walk_tree(&1, opts))
    |> List.to_tuple()
  end

  defp walk_tree(other, _opts), do: other

  @spec normalize_vars(map | any, keyword) :: map | any
  def normalize_vars(vars, opts \\ [])

  def normalize_vars(vars, opts) when is_map(vars) and not is_struct(vars) do
    Map.new(vars, fn {k, v} -> {k, walk_vars(v, opts)} end)
  end

  def normalize_vars(other, _opts), do: other

  defp walk_vars(tuple, opts) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&walk_vars(&1, opts))
    |> List.to_tuple()
  end

  defp walk_vars(value, opts) when is_binary(value) do
    case parse_if_interpolated(value, opts) do
      nil -> value
      template -> %InterpolatedString{ast: template, original: value}
    end
  end

  defp walk_vars(value, opts) when is_list(value), do: Enum.map(value, &walk_vars(&1, opts))

  defp walk_vars(value, opts) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {k, v} -> {k, walk_vars(v, opts)} end)
  end

  defp walk_vars(value, _opts), do: value

  defp parse_if_interpolated(value, opts) do
    if String.contains?(value, "{{") or String.contains?(value, "{%") do
      parse_value(value, opts)
    end
  end

  defp parse_value(value, opts) do
    case Gas.parse(value, opts) do
      {:ok, %Template{parsed_template: tree} = template} -> if_interpolated(tree, template, opts)
      {:error, _} -> nil
    end
  end

  # Liquid in settings data is a template too, so it compiles like the theme around it.
  defp if_interpolated(tree, template) do
    if text_only?(tree), do: nil, else: template
  end

  defp if_interpolated(tree, template, opts) do
    with %Template{} = t <- if_interpolated(tree, template),
         true <- Keyword.get(opts, :codegen, false),
         {:ok, module} <- Gas.Compiler.Codegen.compile_cached(tree, %{}, opts) do
      %{t | module: module}
    else
      other when is_struct(other) -> other
      _ -> if_interpolated(tree, template)
    end
  end

  defp text_only?([]), do: true
  defp text_only?([%Text{} | rest]), do: text_only?(rest)
  defp text_only?(_), do: false
end
