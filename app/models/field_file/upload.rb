# The Field accepts only a file uploaded in this request. Active Storage would
# also take a signed blob ID, which would let someone reattach a blob they once
# had a URL for (for example from a discarded message) into the Field.
module FieldFile::Upload

  module_function

  def uploaded_file?(value)
    value.is_a?(ActionDispatch::Http::UploadedFile)
  end

end
