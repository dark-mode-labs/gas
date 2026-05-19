defprotocol Gas.Matcher do
  @fallback_to_any true
  @doc "Assigns context to values"
  def match(_, _)
end

defimpl Gas.Matcher, for: Any do
  def match(data, []), do: {:ok, data}

  def match(_, _), do: {:error, :not_found}
end

defimpl Gas.Matcher, for: List do
  def match(data, []), do: {:ok, data}

  def match(data, ["first"]), do: {:ok, Enum.at(data, 0)}
  def match(data, ["last"]), do: {:ok, Enum.at(data, -1)}
  def match(data, ["size"]), do: {:ok, Enum.count(data)}

  def match(data, [key | keys]) when is_integer(key) do
    case Enum.fetch(data, key) do
      {:ok, value} -> @protocol.match(value, keys)
      _ -> {:error, :not_found}
    end
  end

  def match(data, keys) when is_list(keys) do
    result =
      data
      |> List.flatten()
      |> Enum.reduce([], fn element, acc ->
        case @protocol.match(element, keys) do
          {:ok, resolved_value} ->
            [resolved_value | acc]

          _ ->
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, result}
  end

  def match(_data, _) do
    {:error, :not_found}
  end
end

defimpl Gas.Matcher, for: Map do
  def match(data, []) do
    {:ok, data}
  end

  # Maps are not ordered so these are here just for consistency with the Liquid implementation
  # as we must return something

  def match(data, [key | keys]) do
    case Map.fetch(data, key) do
      {:ok, value} -> recurse(value, keys)
      :error -> special(data, key, keys)
    end
  end

  # Recurse without protocol dispatch when nested values are plain maps.
  defp recurse(value, []), do: {:ok, value}

  defp recurse(value, [key | keys]) when is_map(value) and not is_struct(value) do
    case Map.fetch(value, key) do
      {:ok, v} -> recurse(v, keys)
      :error -> special(value, key, keys)
    end
  end

  defp recurse(value, keys), do: @protocol.match(value, keys)

  defp special(data, "size", keys), do: recurse(map_size(data), keys)
  defp special(_data, _key, _keys), do: {:error, :not_found}
end

defimpl Gas.Matcher, for: BitString do
  def match(current, []), do: {:ok, current}

  def match(data, ["size"]) do
    {:ok, String.length(data)}
  end

  def match(_data, [i | _]) when is_integer(i) do
    {:error, :not_found}
  end

  def match(_data, [i | _]) when is_binary(i) do
    {:error, :not_found}
  end
end

defimpl Gas.Matcher, for: Atom do
  def match(current, []) when is_nil(current), do: {:ok, nil}
  def match(data, []), do: {:ok, data}
  def match(nil, _), do: {:error, :not_found}

  @doc """
  Matches all remaining cases
  """
  def match(_current, [key]) when is_binary(key), do: {:error, :not_found}
end

defimpl Gas.Matcher, for: Tuple do
  def match(data, []), do: {:ok, data}

  def match(data, ["size"]) do
    {:ok, tuple_size(data)}
  end

  def match(data, [key | keys]) when is_integer(key) do
    try do
      elem(data, key)
      |> @protocol.match(keys)
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end
end
