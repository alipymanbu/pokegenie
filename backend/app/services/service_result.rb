# Lightweight result object returned by service objects so controllers can map
# outcomes to HTTP status codes without exceptions for expected flows.
ServiceResult = Struct.new(:ok, :code, :data, keyword_init: true) do
  def ok? = ok

  def self.success(code: :ok, **data) = new(ok: true, code: code, data: data)
  def self.failure(code:, **data)      = new(ok: false, code: code, data: data)
end
