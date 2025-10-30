defmodule Solid.Tags.RenderTag do
  alias Solid.{Argument, Context, Parser}
  alias Solid.Parser.Loc

  @type t :: %__MODULE__{
          loc: Loc.t(),
          template: binary,
          arguments:
            {:with, {source :: Argument.t(), destination :: binary}}
            | {:for, {source :: Argument.t(), destination :: binary}}
            | %{binary => Argument.t()}
        }

  @enforce_keys [:loc, :template, :arguments]
  defstruct [:loc, :template, :arguments]

  @behaviour Solid.Tag

  @impl true
  def parse("render", loc, context) do
    with {:ok, tokens, context} <- Solid.Lexer.tokenize_tag_end(context),
         {:ok, template, tokens} <- template(tokens),
         {:ok, arguments} <- parse_arguments(tokens, template) do
      {:ok, %__MODULE__{loc: loc, template: template, arguments: arguments}, context}
    end
  end

  defp parse_arguments(tokens, template) do
    case tokens do
      [{:identifier, _, "with"} | rest] -> parse_with_or_for_arguments(rest, :with, template)
      [{:identifier, _, "for"} | rest] -> parse_with_or_for_arguments(rest, :for, template)
      # Parse optional comma
      [{:comma, _} | rest] -> parse_list_of_arguments(rest)
      # No initial comma
      [{:identifier, _, _} | _] -> parse_list_of_arguments(tokens)
      [{:end, _}] -> {:ok, %{}}
      _ -> {:error, "Expected arguments, 'with' or 'for'", Parser.meta_head(tokens)}
    end
  end

  defp parse_with_or_for_arguments(tokens, type, template) do
    with {:ok, first, tokens} <- Argument.parse(tokens) do
      case tokens do
        [{:identifier, _, "as"}, {:identifier, _, key}, {:end, _}] ->
          {:ok, {type, {first, key}}}

        [{:end, _}] ->
          {:ok, {type, {first, template}}}

        _ ->
          {:error, "Unexpected token", Parser.meta_head(tokens)}
      end
    end
  end

  defp parse_list_of_arguments(tokens, acc \\ %{}) do
    case tokens do
      [{:identifier, _, key}, {:colon, _} | rest] ->
        with {:ok, value, rest} <- Argument.parse(rest) do
          acc = Map.put(acc, key, value)

          case rest do
            [{:comma, _} | rest] ->
              parse_list_of_arguments(rest, acc)

            [{:end, _}] ->
              {:ok, acc}

            _ ->
              {:error, "Expected arguments, 'with' or 'for'", Solid.Parser.meta_head(rest)}
          end
        end

      _ ->
        {:error, "Expected arguments, 'with' or 'for'", Solid.Parser.meta_head(tokens)}
    end
  end

  defp template(tokens) do
    case tokens do
      [{:string, _meta, value, _quotes} | rest] ->
        {:ok, %Solid.Literal{value: value, loc: nil}, rest}

      [{:identifier, _meta, value} | rest] ->
        {:ok, %Solid.Variable{identifier: value, original_name: value, accesses: [], loc: nil},
         rest}

      _ ->
        {:error, "Expected template name as a quoted string", tokens}
    end
  end

  defimpl Solid.Renderable do
    def render(tag, context, options) do
      tag
      |> get_template_name(context, options)
      |> get_or_put_cache(options)
      |> do_render(tag, context, options)
    end

    defp get_template_name(tag, context, options) do
      {:ok, template_name, _context} = Argument.get(tag.template, context, [], options)

      template_name
    end

    defp get_or_put_cache(template, options) do
      cache_module = Keyword.get(options, :cache_module, Solid.Caching.NoCache)

      case cache_module.get(template) do
        {:ok, cached_template} ->
          {:ok, cached_template}

        {:error, :not_found} ->
          {file_system, instance} = options[:file_system] || {Solid.BlankFileSystem, nil}

          file_system.read_template_file(template, instance)
          |> parse_and_cache_partial(options, template, cache_module)
      end
    end

    defp do_render({:error, %{loc: _} = exception}, tag, context, _options) do
      {[], Solid.Context.put_errors(context, [%{exception | loc: tag.loc}])}
    end

    defp do_render({:error, exception}, _tag, context, _options) do
      {[], Solid.Context.put_errors(context, [exception])}
    end

    defp do_render({:ok, []}, _tag, context, _options) do
      {[], context}
    end

    defp do_render({:ok, {_template_name, %Solid.Template{} = template}}, tag, context, options) do
      do_render({:ok, template}, tag, context, options)
    end

    defp do_render({:ok, %Solid.Template{} = template}, tag, context, options) do
      {inner_contexts, context} = build_contexts(tag.arguments, context, options)

      {rendered_text, context} =
        Enum.reduce(inner_contexts, {[], context}, fn inner_context, {result, context} ->
          case Solid.render(template, inner_context, options) do
            {:ok, rendered_text, errors} ->
              {[rendered_text | result], Solid.Context.put_errors(context, Enum.reverse(errors))}

            {:error, errors, rendered_text} ->
              {[rendered_text | result], Solid.Context.put_errors(context, Enum.reverse(errors))}
          end
        end)

      {Enum.reverse(rendered_text), context}
    end

    defp build_contexts({:with, {source, destination}}, outer_context, options) do
      {:ok, destination, _context} =
        if is_struct(destination) do
          Argument.get(destination, outer_context, [], options)
        else
          {:ok, destination, outer_context}
        end

      {:ok, value, outer_context} = Argument.get(source, outer_context, [], options)
      inner_context = %Context{vars: %{destination => value}}

      {[inner_context], outer_context}
    end

    defp build_contexts({:for, {source, destination}}, outer_context, options) do
      {:ok, destination, _context} =
        if is_struct(destination) do
          Argument.get(destination, outer_context, [], options)
        else
          {:ok, destination, outer_context}
        end

      {:ok, value, outer_context} = Argument.get(source, outer_context, [], options)

      if is_list(value) do
        length = Enum.count(value)

        inner_contexts =
          value
          |> Enum.with_index(0)
          |> Enum.map(fn {v, index} ->
            forloop = build_forloop_map(index, length)
            %Context{vars: %{destination => v}, iteration_vars: %{"forloop" => forloop}}
          end)

        {inner_contexts, outer_context}
      else
        inner_context = %Context{vars: %{destination => value}}
        {[inner_context], outer_context}
      end
    end

    defp build_contexts(args, outer_context, options) do
      {vars, outer_context} =
        Enum.reduce(args, {%{}, outer_context}, fn {k, v}, {args, outer_context} ->
          {:ok, value, outer_context} = Argument.get(v, outer_context, [], options)
          {Map.put(args, k, value), outer_context}
        end)

      inner_context = %Context{vars: vars}
      {[inner_context], outer_context}
    end

    defp build_forloop_map(index, length) do
      %{
        "index" => index + 1,
        "index0" => index,
        "rindex" => length - index,
        "rindex0" => length - index - 1,
        "first" => index == 0,
        "last" => length == index + 1,
        "length" => length
      }
    end

    defp parse_and_cache_partial({:ok, template_str}, options, cache_key, cache_module) do
      with {:ok, template} <- Solid.parse(template_str, options) do
        cache_module.put(cache_key, template)
        {:ok, template}
      end
    end

    defp parse_and_cache_partial(other, _options, _cache_key, _cache_module), do: other
  end
end
