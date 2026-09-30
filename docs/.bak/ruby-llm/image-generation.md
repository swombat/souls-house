# RubyLLM Image Generation Documentation

RubyLLM provides powerful image generation capabilities using AI models like DALL-E 3 and Imagen, with seamless Rails integration including ActiveStorage support.

## Version Information
- Documentation source: https://rubyllm.com/image-generation/
- Fetched: 2025-10-05

## Key Concepts

- **Image Generation**: Create images from text prompts using AI models
- **Multiple Providers**: Support for various AI image generation services
- **ActiveStorage Integration**: Seamless Rails file storage integration
- **Flexible Parameters**: Customizable image dimensions and quality settings
- **Base64 Support**: Direct image data access for various use cases

## Supported Models

RubyLLM supports various image generation models:
- **DALL-E 3**: OpenAI's latest image generation model
- **Imagen**: Google's image generation model
- **Custom providers**: Configurable through provider settings

### Model Configuration

```ruby
# Global configuration
RubyLLM.configure do |config|
  config.default_image_model = "gpt-image-1"
  config.openai_api_key = Rails.application.credentials.openai_api_key
end

# Per-request model specification
image = RubyLLM.paint("A red panda coding Ruby", model: "imagen-3.0-generate-002")
```

## Basic Image Generation

### Simple Image Generation

```ruby
# Basic usage
image = RubyLLM.paint("A photorealistic image of a red panda coding Ruby")

# Access image data
puts image.url        # Image URL (if available)
puts image.mime_type  # e.g., "image/png"
image_data = image.data # Base64 encoded image data
```

### Image with Custom Parameters

```ruby
# Generate with specific dimensions
image = RubyLLM.paint(
  "A serene mountain landscape at sunset",
  size: "1792x1024",  # Custom dimensions
  quality: "hd"       # High quality (if supported by model)
)
```

### Saving Images Locally

```ruby
# Save to file system
def generate_and_save_image(prompt, filename)
  image = RubyLLM.paint(prompt)

  # Save using built-in method
  image.save(filename)

  # Or save manually
  File.write(filename, image.to_blob)

  filename
end

# Usage
image_path = generate_and_save_image(
  "A modern office workspace with plants",
  "workspace_#{Time.current.to_i}.png"
)
```

## Rails ActiveStorage Integration

### Model Setup

```ruby
class Product < ApplicationRecord
  has_one_attached :generated_image
  has_many_attached :variations

  def generate_product_image(style: "photorealistic")
    prompt = build_image_prompt(style)
    image = RubyLLM.paint(prompt)

    attach_generated_image(image, "product-#{id}-#{style}")
  end

  private

  def build_image_prompt(style)
    "#{style} image of #{name}: #{description}"
  end

  def attach_generated_image(image, filename)
    image_io = StringIO.new(image.to_blob)

    generated_image.attach(
      io: image_io,
      filename: "#{filename}.png",
      content_type: image.mime_type
    )
  end
end
```

### Controller Implementation

```ruby
class ProductImagesController < ApplicationController
  before_action :set_product

  def generate
    GenerateProductImageJob.perform_later(@product.id, image_params)
    render json: { status: "generating", message: "Image generation started" }
  end

  def show
    if @product.generated_image.attached?
      redirect_to rails_blob_path(@product.generated_image)
    else
      render json: { error: "No image generated" }, status: :not_found
    end
  end

  private

  def set_product
    @product = Product.find(params[:product_id])
  end

  def image_params
    params.permit(:style, :size, :quality, :custom_prompt)
  end
end
```

### Background Job for Image Generation

```ruby
class GenerateProductImageJob < ApplicationJob
  queue_as :image_generation

  def perform(product_id, options = {})
    product = Product.find(product_id)

    prompt = build_prompt(product, options)

    begin
      image = RubyLLM.paint(prompt, **generation_options(options))

      attach_image_to_product(product, image, options)

      # Notify user of completion
      ActionCable.server.broadcast(
        "product_#{product.id}",
        {
          event: "image_generated",
          image_url: rails_blob_url(product.generated_image),
          product_id: product.id
        }
      )
    rescue => e
      Rails.logger.error "Image generation failed: #{e.message}"

      ActionCable.server.broadcast(
        "product_#{product.id}",
        {
          event: "image_generation_failed",
          error: e.message,
          product_id: product.id
        }
      )
    end
  end

  private

  def build_prompt(product, options)
    base_prompt = "#{options[:style] || 'photorealistic'} image of #{product.name}"
    base_prompt += ": #{product.description}" if product.description.present?
    base_prompt += ". #{options[:custom_prompt]}" if options[:custom_prompt].present?
    base_prompt
  end

  def generation_options(options)
    {
      size: options[:size] || "1024x1024",
      quality: options[:quality] || "standard"
    }.compact
  end

  def attach_image_to_product(product, image, options)
    image_io = StringIO.new(image.to_blob)

    filename = "#{product.name.parameterize}-#{options[:style]}-#{Time.current.to_i}.png"

    product.generated_image.attach(
      io: image_io,
      filename: filename,
      content_type: image.mime_type,
      metadata: {
        generated_at: Time.current,
        style: options[:style],
        ai_model: RubyLLM.configuration.default_image_model
      }
    )
  end
end
```

## Advanced Use Cases

### Image Variations Generator

```ruby
class ImageVariationService
  def initialize(base_image_description)
    @base_description = base_image_description
  end

  def generate_variations(styles: ["photorealistic", "artistic", "minimalist"])
    variations = []

    styles.each do |style|
      prompt = "#{style} style: #{@base_description}"

      begin
        image = RubyLLM.paint(prompt)
        variations << {
          style: style,
          image: image,
          prompt: prompt
        }
      rescue => e
        Rails.logger.error "Failed to generate #{style} variation: #{e.message}"
      end
    end

    variations
  end

  def save_variations_for_product(product, variations)
    variations.each do |variation|
      image_io = StringIO.new(variation[:image].to_blob)

      product.variations.attach(
        io: image_io,
        filename: "#{product.name.parameterize}-#{variation[:style]}.png",
        content_type: variation[:image].mime_type,
        metadata: {
          style: variation[:style],
          prompt: variation[:prompt],
          generated_at: Time.current
        }
      )
    end
  end
end

# Usage
service = ImageVariationService.new("A modern ergonomic office chair")
variations = service.generate_variations
service.save_variations_for_product(product, variations)
```

### Bulk Image Generation

```ruby
class BulkImageGenerationJob < ApplicationJob
  queue_as :bulk_operations

  def perform(product_ids, template_prompt)
    products = Product.where(id: product_ids)

    products.find_each do |product|
      prompt = template_prompt.gsub("{product_name}", product.name)
                             .gsub("{product_description}", product.description || "")

      begin
        image = RubyLLM.paint(prompt)
        attach_generated_image(product, image, prompt)

        sleep(1) # Rate limiting
      rescue => e
        Rails.logger.error "Bulk generation failed for product #{product.id}: #{e.message}"
      end
    end
  end

  private

  def attach_generated_image(product, image, prompt)
    image_io = StringIO.new(image.to_blob)

    product.generated_image.attach(
      io: image_io,
      filename: "bulk-#{product.id}-#{Time.current.to_i}.png",
      content_type: image.mime_type,
      metadata: {
        generation_type: "bulk",
        prompt: prompt,
        generated_at: Time.current
      }
    )
  end
end
```

## Image Processing and Optimization

### Image Resizing and Optimization

```ruby
class ImageProcessor
  def self.process_generated_image(image, options = {})
    # Convert RubyLLM image to blob
    image_blob = image.to_blob

    # Use ImageProcessing for optimization
    processed = ImageProcessing::Vips
      .source(StringIO.new(image_blob))
      .resize_to_limit(options[:max_width] || 1200, options[:max_height] || 1200)
      .convert("webp")
      .saver(quality: options[:quality] || 85)
      .call

    {
      data: processed.read,
      content_type: "image/webp",
      filename: "processed-#{Time.current.to_i}.webp"
    }
  end
end

# Usage in job
def attach_optimized_image(product, image)
  processed = ImageProcessor.process_generated_image(image, max_width: 800, quality: 90)

  product.optimized_image.attach(
    io: StringIO.new(processed[:data]),
    filename: processed[:filename],
    content_type: processed[:content_type]
  )
end
```

### Image Analysis Integration

```ruby
class GeneratedImageAnalyzer
  def self.analyze_and_tag(product)
    return unless product.generated_image.attached?

    # Analyze the generated image
    analysis_prompt = "Analyze this product image and provide 5 relevant tags"

    chat = RubyLLM.chat
    chat.attach(product.generated_image.blob)

    response = chat.ask(analysis_prompt)
    tags = extract_tags_from_response(response)

    product.update(ai_generated_tags: tags)
  end

  private

  def self.extract_tags_from_response(response)
    # Extract tags from AI response
    response.scan(/\b\w+\b/).uniq.first(5)
  end
end
```

## Prompt Engineering Best Practices

### Effective Prompt Construction

```ruby
class ImagePromptBuilder
  STYLE_MODIFIERS = {
    photorealistic: "photorealistic, high resolution, professional photography",
    artistic: "artistic, painted style, creative interpretation",
    minimalist: "minimalist design, clean lines, simple composition",
    vintage: "vintage style, retro aesthetic, classic look"
  }.freeze

  QUALITY_MODIFIERS = {
    high: "high quality, detailed, sharp focus",
    standard: "good quality, clear details",
    creative: "creative, unique perspective, artistic flair"
  }.freeze

  def self.build_product_prompt(product, style: :photorealistic, quality: :high)
    base = "#{STYLE_MODIFIERS[style]} image of #{product.name}"
    base += ", #{product.description}" if product.description.present?
    base += ", #{QUALITY_MODIFIERS[quality]}"
    base += ", white background" if style == :minimalist

    base
  end

  def self.build_scene_prompt(product, scene: :studio)
    scenes = {
      studio: "in a professional photography studio with soft lighting",
      lifestyle: "in a real-world setting being used naturally",
      workspace: "on a modern desk in a bright office environment",
      outdoor: "in a natural outdoor setting with good lighting"
    }

    "#{STYLE_MODIFIERS[:photorealistic]} image of #{product.name} #{scenes[scene]}"
  end
end

# Usage
prompt = ImagePromptBuilder.build_product_prompt(
  product,
  style: :artistic,
  quality: :high
)
image = RubyLLM.paint(prompt)
```

## Error Handling and Retry Logic

### Comprehensive Error Handling

```ruby
class RobustImageGenerator
  MAX_RETRIES = 3
  RETRY_DELAY = 2.seconds

  def self.generate_with_retries(prompt, options = {})
    attempt = 1

    begin
      image = RubyLLM.paint(prompt, **options)
      Rails.logger.info "Image generated successfully on attempt #{attempt}"
      image
    rescue RubyLLM::BadRequestError => e
      Rails.logger.error "Bad request for image generation: #{e.message}"
      raise # Don't retry bad requests
    rescue RubyLLM::RateLimitError => e
      if attempt < MAX_RETRIES
        Rails.logger.warn "Rate limit hit, retrying in #{RETRY_DELAY} seconds (attempt #{attempt})"
        sleep(RETRY_DELAY * attempt) # Exponential backoff
        attempt += 1
        retry
      else
        Rails.logger.error "Max retries exceeded for rate limiting"
        raise
      end
    rescue RubyLLM::AuthenticationError => e
      Rails.logger.error "Authentication failed: #{e.message}"
      raise # Don't retry auth errors
    rescue StandardError => e
      if attempt < MAX_RETRIES
        Rails.logger.warn "Image generation failed, retrying (attempt #{attempt}): #{e.message}"
        attempt += 1
        sleep(RETRY_DELAY)
        retry
      else
        Rails.logger.error "Max retries exceeded: #{e.message}"
        raise
      end
    end
  end
end

# Usage in jobs
class GenerateProductImageJob < ApplicationJob
  def perform(product_id, options = {})
    product = Product.find(product_id)
    prompt = build_prompt(product, options)

    begin
      image = RobustImageGenerator.generate_with_retries(prompt, options)
      attach_image_to_product(product, image)
      notify_success(product)
    rescue => e
      notify_failure(product, e.message)
    end
  end
end
```

## Performance and Cost Optimization

### Caching Generated Images

```ruby
class ImageGenerationCache
  def self.cached_generate(prompt, options = {})
    cache_key = cache_key_for(prompt, options)

    Rails.cache.fetch(cache_key, expires_in: 24.hours) do
      image = RubyLLM.paint(prompt, **options)
      {
        data: image.to_blob,
        mime_type: image.mime_type,
        url: image.url
      }
    end
  end

  private

  def self.cache_key_for(prompt, options)
    content = [prompt, options.sort].join("|")
    "image_generation:#{Digest::MD5.hexdigest(content)}"
  end
end
```

### Cost Monitoring

```ruby
class ImageGenerationCostTracker
  def self.track_generation(prompt, options, image)
    cost_estimate = estimate_cost(options)

    ImageGenerationLog.create!(
      prompt: prompt,
      options: options,
      estimated_cost: cost_estimate,
      model: RubyLLM.configuration.default_image_model,
      generated_at: Time.current,
      file_size: image.to_blob.size
    )
  end

  private

  def self.estimate_cost(options)
    # Rough cost estimation based on size and quality
    base_cost = 0.02 # Base cost in USD
    size_multiplier = size_cost_multiplier(options[:size])
    quality_multiplier = quality_cost_multiplier(options[:quality])

    base_cost * size_multiplier * quality_multiplier
  end

  def self.size_cost_multiplier(size)
    case size
    when "1024x1024" then 1.0
    when "1792x1024", "1024x1792" then 1.5
    else 1.0
    end
  end

  def self.quality_cost_multiplier(quality)
    quality == "hd" ? 2.0 : 1.0
  end
end
```

## Testing Image Generation

### RSpec Testing Examples

```ruby
RSpec.describe "Image Generation" do
  let(:product) { create(:product, name: "Ergonomic Chair", description: "Comfortable office chair") }

  describe "#generate_product_image" do
    it "generates and attaches an image" do
      # Mock the image generation
      mock_image = double("RubyLLM::Image",
        to_blob: "mock_image_data",
        mime_type: "image/png",
        url: "https://example.com/image.png"
      )

      allow(RubyLLM).to receive(:paint).and_return(mock_image)

      product.generate_product_image

      expect(product.generated_image).to be_attached
      expect(RubyLLM).to have_received(:paint).with(/Ergonomic Chair/)
    end

    it "handles generation errors gracefully" do
      allow(RubyLLM).to receive(:paint).and_raise(RubyLLM::BadRequestError, "Invalid prompt")

      expect {
        product.generate_product_image
      }.not_to raise_error

      expect(product.generated_image).not_to be_attached
    end
  end
end

# Feature test with Capybara
RSpec.describe "Product image generation", type: :feature do
  it "allows users to generate product images" do
    product = create(:product)

    visit product_path(product)
    click_button "Generate Image"

    expect(page).to have_content("Image generation started")

    # Simulate job completion
    GenerateProductImageJob.perform_now(product.id, {})

    visit current_path
    expect(page).to have_css("img[src*='#{product.generated_image.filename}']")
  end
end
```

## Important Considerations

### Security and Content Safety
- Always validate and sanitize user-provided prompts
- Implement content moderation for user-generated prompts
- Store generation logs for audit purposes
- Monitor for inappropriate content requests

### Performance Guidelines
- Use background jobs for image generation to avoid blocking requests
- Implement proper rate limiting to respect API limits
- Cache frequently requested images
- Monitor API costs and usage patterns

### Storage Management
- Regularly clean up unused generated images
- Implement image compression and optimization
- Consider cloud storage for large volumes
- Set up automated backups for important generated content

## Related Documentation
- [RubyLLM Configuration Guide](https://rubyllm.com/configuration/)
- [Rails ActiveStorage Guide](https://guides.rubyonrails.org/active_storage_overview.html)
- [Image Processing with Rails](https://github.com/janko/image_processing)