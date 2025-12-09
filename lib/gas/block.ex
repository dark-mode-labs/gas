defprotocol Gas.Block do
  @fallback_to_any true
  @spec blank?(t) :: boolean
  def blank?(body)
end

defimpl Gas.Block, for: Any do
  def blank?(_body), do: false
end

defimpl Gas.Block, for: List do
  def blank?(list), do: Enum.all?(list, &Gas.Block.blank?/1)
end
