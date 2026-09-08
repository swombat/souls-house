# frozen_string_literal: true

module House
  # Shared helpers for reading and rewriting config/house.env(.example) while
  # preserving every comment and blank line exactly — callers only ever
  # replace the value half of a single KEY=value line.
  module EnvFile
    LINE = /\A(\s*)([A-Z_][A-Z0-9_]*)=(.*)\z/

    module_function

    # Returns the file's KEY=value lines in order, each with its default
    # value and the (possibly empty) block of comment lines immediately
    # above it — the block a fork should see when being asked for that key.
    # A comment block separated from the next key by a blank line (the
    # file's header, or a stray note) belongs to nothing and is dropped.
    def entries(text)
      entries = []
      comments = []

      text.each_line do |line|
        stripped = line.chomp
        if (match = LINE.match(stripped))
          entries << { key: match[2], default: unquote(match[3]), comments: comments }
          comments = []
        elsif stripped.strip.start_with?("#")
          comments << line
        else
          comments = []
        end
      end

      entries
    end

    # Returns +text+ with KEY's value replaced by +value+, leaving every
    # other line — including KEY's own leading whitespace and every comment
    # — untouched. Raises if KEY has no line to replace.
    def set_value(text, key, value)
      found = false
      lines = text.lines.map do |line|
        match = LINE.match(line.chomp)
        next line unless match && match[2] == key

        found = true
        "#{match[1]}#{key}=#{value}\n"
      end
      raise "#{key} not found in this file" unless found

      lines.join
    end

    # Reads +path+, replaces KEY's value, and writes it back.
    def replace_value(path, key, value)
      File.write(path, set_value(File.read(path), key, value))
    end

    def unquote(value)
      value = value.strip
      if value.length >= 2 && ((value.start_with?('"') && value.end_with?('"')) ||
                                (value.start_with?("'") && value.end_with?("'")))
        value[1..-2]
      else
        value
      end
    end
  end
end
