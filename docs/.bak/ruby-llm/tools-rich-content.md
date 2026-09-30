# RubyLLM Tools - Rich Content

## Overview

RubyLLM tools can return rich content beyond simple text, including images, files, documents, and multimedia attachments. This enables tools to provide comprehensive, multimodal responses that enhance the AI conversation experience.

## RubyLLM::Content Objects

The `RubyLLM::Content` class allows tools to return text combined with file attachments:

```ruby
class AnalysisReport < RubyLLM::Tool
  description "Generates analysis report with charts and data files"

  param :data_type, desc: "Type of data to analyze"

  def execute(data_type:)
    # Generate analysis
    report_text = generate_analysis(data_type)

    # Create visualizations
    chart_path = create_chart(data_type)
    csv_path = export_data(data_type)

    # Return content with attachments
    RubyLLM::Content.new(
      report_text,
      [chart_path, csv_path]
    )
  end

  private

  def generate_analysis(data_type)
    "Analysis complete for #{data_type}. See attached chart and raw data file."
  end

  def create_chart(data_type)
    # Generate chart using your preferred library
    # Return file path
    "/tmp/#{data_type}_chart.png"
  end

  def export_data(data_type)
    # Export data to CSV
    "/tmp/#{data_type}_data.csv"
  end
end
```

## Automatic File Type Detection

RubyLLM 1.3.0+ automatically detects file types, so you don't need to categorize them:

```ruby
class DocumentProcessor < RubyLLM::Tool
  description "Processes documents and returns results with attachments"

  param :document_id, desc: "Document ID to process"

  def execute(document_id:)
    document = Document.find(document_id)

    # Process document and create various output files
    pdf_report = generate_pdf_report(document)
    summary_image = create_summary_visualization(document)
    data_export = export_to_excel(document)

    # Mix and match different file types
    RubyLLM::Content.new(
      "Document processing complete. Generated PDF report, summary chart, and data export.",
      [pdf_report, summary_image, data_export]
    )
  end
end
```

## Image Generation Tools

Tools can generate images using RubyLLM's image generation capabilities:

```ruby
class DiagramGenerator < RubyLLM::Tool
  description "Creates diagrams and visual representations"

  param :description, desc: "Description of diagram to create"
  param :style, desc: "Visual style (technical, artistic, simple)", required: false

  def execute(description:, style: "technical")
    # Generate image using RubyLLM
    prompt = "#{style} diagram: #{description}"
    image = RubyLLM.paint(prompt)

    # Save to temporary file
    temp_path = Rails.root.join('tmp', "diagram_#{SecureRandom.hex(8)}.png")
    saved_path = image.save(temp_path)

    RubyLLM::Content.new(
      "Generated #{style} diagram based on: #{description}",
      [saved_path]
    )
  end
end
```

## Working with Existing Files

Tools can return existing files from your Rails application:

```ruby
class ReportExporter < RubyLLM::Tool
  description "Exports existing reports and documents"

  param :report_id, desc: "Report ID to export"
  param :format, desc: "Export format (pdf, csv, xlsx)", required: false

  def execute(report_id:, format: "pdf")
    report = Report.find(report_id)

    case format.downcase
    when "pdf"
      file_path = generate_pdf_export(report)
    when "csv"
      file_path = generate_csv_export(report)
    when "xlsx"
      file_path = generate_xlsx_export(report)
    else
      return { error: "Unsupported format: #{format}" }
    end

    RubyLLM::Content.new(
      "Exported report '#{report.title}' as #{format.upcase}",
      [file_path]
    )
  end

  private

  def generate_pdf_export(report)
    # Use a gem like Prawn or WickedPDF
    pdf_content = generate_pdf_content(report)
    path = Rails.root.join('tmp', "report_#{report.id}.pdf")
    File.write(path, pdf_content)
    path.to_s
  end
end
```

## Rails Active Storage Integration

Tools can work seamlessly with Active Storage attachments:

```ruby
class FileManager < RubyLLM::Tool
  description "Manages user files and attachments"

  param :user_id, desc: "User ID"
  param :operation, desc: "Operation: list, download, or process"

  def execute(user_id:, operation:)
    user = User.find(user_id)

    case operation
    when "list"
      list_user_files(user)
    when "download"
      download_user_files(user)
    when "process"
      process_user_files(user)
    end
  end

  private

  def download_user_files(user)
    if user.documents.attached?
      # Create temporary copies of attached files
      file_paths = user.documents.map do |doc|
        temp_path = Rails.root.join('tmp', doc.filename.to_s)
        File.open(temp_path, 'wb') do |file|
          doc.download { |chunk| file.write(chunk) }
        end
        temp_path.to_s
      end

      RubyLLM::Content.new(
        "Downloaded #{file_paths.length} files for user #{user.name}",
        file_paths
      )
    else
      { message: "No files found for user #{user.name}" }
    end
  end

  def process_user_files(user)
    processed_files = []

    user.documents.each do |doc|
      if doc.image?
        # Process image
        processed_path = process_image(doc)
        processed_files << processed_path
      elsif doc.content_type.include?('pdf')
        # Process PDF
        processed_path = process_pdf(doc)
        processed_files << processed_path
      end
    end

    RubyLLM::Content.new(
      "Processed #{processed_files.length} files",
      processed_files
    )
  end
end
```

## URL-based Content

Tools can reference remote files or generate URLs:

```ruby
class WebContentTool < RubyLLM::Tool
  description "Fetches and processes web content"

  param :url, desc: "URL to process"

  def execute(url:)
    # Download and process remote content
    response = Faraday.get(url)

    # Save locally for processing
    filename = File.basename(URI.parse(url).path)
    local_path = Rails.root.join('tmp', filename)
    File.write(local_path, response.body)

    # Process the file
    processed_content = process_file(local_path)

    RubyLLM::Content.new(
      "Downloaded and processed content from #{url}",
      [local_path.to_s, processed_content]
    )
  end
end
```

## Video and Audio Support

Tools can work with multimedia content:

```ruby
class MediaProcessor < RubyLLM::Tool
  description "Processes video and audio files"

  param :media_type, desc: "Type of media: video or audio"
  param :file_id, desc: "File ID to process"

  def execute(media_type:, file_id:)
    media_file = MediaFile.find(file_id)

    case media_type
    when "video"
      process_video(media_file)
    when "audio"
      process_audio(media_file)
    end
  end

  private

  def process_video(media_file)
    # Process video file (extract frames, generate thumbnail, etc.)
    thumbnail_path = extract_video_thumbnail(media_file)
    transcript_path = generate_video_transcript(media_file)

    RubyLLM::Content.new(
      "Processed video: #{media_file.filename}. Generated thumbnail and transcript.",
      [thumbnail_path, transcript_path]
    )
  end

  def process_audio(media_file)
    # Process audio file (generate waveform, transcript, etc.)
    waveform_path = generate_audio_waveform(media_file)
    transcript_path = generate_audio_transcript(media_file)

    RubyLLM::Content.new(
      "Processed audio: #{media_file.filename}. Generated waveform and transcript.",
      [waveform_path, transcript_path]
    )
  end
end
```

## Working with Binary Data

Tools can handle raw binary data and convert it appropriately:

```ruby
class ImageManipulator < RubyLLM::Tool
  description "Manipulates images and returns processed versions"

  param :image_id, desc: "Image ID to process"
  param :operations, desc: "Operations to perform", type: :array

  def execute(image_id:, operations:)
    image = ImageRecord.find(image_id)
    processed_files = []

    operations.each do |operation|
      case operation
      when "resize"
        resized_path = resize_image(image)
        processed_files << resized_path
      when "grayscale"
        grayscale_path = convert_to_grayscale(image)
        processed_files << grayscale_path
      when "thumbnail"
        thumb_path = create_thumbnail(image)
        processed_files << thumb_path
      end
    end

    RubyLLM::Content.new(
      "Applied #{operations.join(', ')} to image #{image.filename}",
      processed_files
    )
  end

  private

  def resize_image(image)
    # Use ImageMagick or similar library
    output_path = Rails.root.join('tmp', "resized_#{image.id}.jpg")

    # Get binary data from Active Storage
    image.file.open do |file|
      # Process with ImageMagick or similar
      # Save to output_path
    end

    output_path.to_s
  end
end
```

## Content Type Handling

Tools can specify content types and metadata:

```ruby
class DocumentConverter < RubyLLM::Tool
  description "Converts documents between formats"

  param :document_id, desc: "Document to convert"
  param :target_format, desc: "Target format (pdf, docx, html)"

  def execute(document_id:, target_format:)
    document = Document.find(document_id)

    # Convert document
    converted_path = convert_document(document, target_format)

    # Return with specific content type information
    content = RubyLLM::Content.new(
      "Converted #{document.filename} to #{target_format.upcase}",
      [converted_path]
    )

    # Add metadata if needed
    content.metadata = {
      original_format: document.format,
      target_format: target_format,
      file_size: File.size(converted_path)
    }

    content
  end
end
```

## Temporary File Management

Best practices for handling temporary files in tools:

```ruby
class TempFileManager < RubyLLM::Tool
  description "Demonstrates proper temporary file handling"

  def execute(**params)
    temp_files = []

    begin
      # Create temporary files
      temp_files << create_temp_file("data.csv")
      temp_files << create_temp_file("chart.png")

      # Process and return content
      RubyLLM::Content.new(
        "Generated temporary files",
        temp_files
      )
    ensure
      # Clean up temporary files after a delay
      cleanup_temp_files(temp_files)
    end
  end

  private

  def create_temp_file(filename)
    path = Rails.root.join('tmp', "tool_#{SecureRandom.hex(8)}_#{filename}")
    # Create file content
    File.write(path, generate_content)
    path.to_s
  end

  def cleanup_temp_files(files)
    # Schedule cleanup job
    CleanupTempFilesJob.perform_later(files)
  end
end

# Clean up job
class CleanupTempFilesJob < ApplicationJob
  def perform(file_paths)
    file_paths.each do |path|
      File.delete(path) if File.exist?(path)
    end
  end
end
```

## Error Handling for Rich Content

```ruby
class RobustContentTool < RubyLLM::Tool
  description "Demonstrates error handling for rich content"

  def execute(**params)
    files_created = []

    begin
      # Create content files
      pdf_path = generate_pdf_report
      files_created << pdf_path

      image_path = create_visualization
      files_created << image_path

      RubyLLM::Content.new(
        "Successfully generated report and visualization",
        files_created
      )
    rescue => e
      # Clean up any files created before error
      files_created.each { |f| File.delete(f) if File.exist?(f) }

      { error: "Failed to generate content: #{e.message}" }
    end
  end
end
```

## Next Steps

- Learn about [Tool Execution Flow](tools-execution-flow.md) - handling complex operations and errors
- Explore [Chat Integration](tools-in-chat.md) - using rich content tools in Rails conversations
- Understand [Callbacks](tools-callbacks.md) - monitoring and responding to tool events with rich content