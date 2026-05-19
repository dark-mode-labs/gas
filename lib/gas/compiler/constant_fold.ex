defmodule Gas.Compiler.ConstantFold do
  @moduledoc """
  Compile-time pass that eliminates `{% if literal %}` / `{% unless literal %}`
  tags whose condition is a single literal (the truthiness is known at
  parse time). The dead branch is removed entirely; the live branch is
  spliced in place of the tag.

  Currently handles only single-literal `UnaryCondition` with no
  filters and no chained and/or — the common "static toggle" case.
  Comparisons against literals (`{% if "x" == "x" %}`) are not folded.
  """

  alias Gas.{Literal, Template, UnaryCondition}
  alias Gas.Tags.IfTag

  @spec run(Template.t()) :: Template.t()
  def run(%Template{parsed_template: tree} = template) do
    %{template | parsed_template: walk(tree)}
  end

  defp walk(list) when is_list(list), do: Enum.flat_map(list, &fold_node/1)

  defp walk(%_struct{} = s) do
    s
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {k, walk(v)} end)
    |> then(&struct(s.__struct__, &1))
  end

  defp walk(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, walk(v)} end)
  end

  defp walk(other), do: other

  defp fold_node(%IfTag{condition: condition, body: body, else_body: else_body, elsifs: []} = tag) do
    case literal_truthy(condition) do
      :unknown ->
        [%{tag | body: walk(body), else_body: walk(else_body)}]

      truthy ->
        live = (tag.tag_name == :if and truthy) or (tag.tag_name == :unless and not truthy)
        if live, do: walk(body), else: walk(else_body)
    end
  end

  defp fold_node(other), do: [walk(other)]

  defp literal_truthy(%UnaryCondition{
         argument: %Literal{value: v},
         argument_filters: [],
         child_condition: nil
       }) do
    truthy?(v)
  end

  defp literal_truthy(_), do: :unknown

  defp truthy?(false), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: true
end
