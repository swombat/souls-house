class FaviconController < ApplicationController

  skip_before_action :require_authentication

  def show
    case params[:format] || "ico"
    when "svg"
      send_svg_favicon
    when "png"
      send_png_favicon(size: 32)
    when "ico"
      send_ico_favicon
    else
      head :not_found
    end
  end

  def apple_touch_icon
    send_png_favicon(size: 180)
  end

  private

  # Keep SVG and raster sources separate so we can change the logo treatment
  # by output type without rewriting the controller flow again.
  def svg_favicon_source_path
    Rails.root.join("public", "favicon.svg")
  end

  def raster_favicon_source_path
    Rails.root.join("public", "favicon.svg")
  end

  def send_svg_favicon
    send_file svg_favicon_source_path, type: "image/svg+xml", disposition: "inline"
  end

  def send_png_favicon(size:)
    png_data = render_png_data(source_path: raster_favicon_source_path, size: size)

    if png_data
      send_data png_data, type: "image/png", disposition: "inline"
    else
      send_svg_favicon
    end
  end

  def send_ico_favicon
    ico_data = render_ico_data(source_path: raster_favicon_source_path)

    if ico_data
      send_data ico_data, type: "image/vnd.microsoft.icon", disposition: "inline"
    else
      send_png_favicon(size: 32)
    end
  end

  def render_png_data(source_path:, size:)
    Tempfile.create([ "favicon", ".png" ]) do |file|
      next unless rasterize_svg(source_path: source_path, output_path: file.path, size: size)

      File.binread(file.path)
    end
  end

  def render_ico_data(source_path:)
    Tempfile.create([ "favicon", ".png" ]) do |png_file|
      next unless rasterize_svg(source_path: source_path, output_path: png_file.path, size: 256)

      Tempfile.create([ "favicon", ".ico" ]) do |ico_file|
        next unless system("magick", png_file.path, "-background", "none", "-define", "icon:auto-resize=16,32,48", ico_file.path)

        File.binread(ico_file.path)
      end
    end
  end

  def rasterize_svg(source_path:, output_path:, size:)
    system("which", "rsvg-convert", out: File::NULL, err: File::NULL) &&
      system("rsvg-convert", "-w", size.to_s, "-h", size.to_s, "-f", "png", "-o", output_path, source_path.to_s)
  end

end
