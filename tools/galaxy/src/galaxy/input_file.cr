require "json"

module Galaxy
  # The file a driver hands `galaxy session send`: plain text, or notes that
  # answer quoted text. Strict, so a typo fails loudly instead of silently
  # dropping what the driver meant to say.
  module InputFile
    record Note, quote : String, note : String

    record Parsed, message : String?, summary : String?, notes : Array(Note) do
      def note_count : Int32
        notes.size
      end

      # The validated input as the `session.send` request carries it.
      def to_detail : Hash(String, JSON::Any)
        detail = {} of String => JSON::Any
        if m = message
          detail["message"] = JSON::Any.new(m)
        else
          if s = summary
            detail["summary"] = JSON::Any.new(s)
          end
          detail["notes"] = JSON::Any.new(notes.map do |n|
            JSON::Any.new({"quote" => JSON::Any.new(n.quote), "note" => JSON::Any.new(n.note)})
          end)
        end
        detail
      end
    end

    SHAPES = <<-SHAPES
      Valid shapes:
        {"message": "Plain text, any length."}
        {"summary": "Optional overall comment.",
         "notes": [{"quote": "text being answered", "note": "the reply"}]}
      SHAPES

    TOP_KEYS  = %w[message summary notes]
    NOTE_KEYS = %w[quote note]

    # The parsed input, or every problem found as "path: problem".
    def self.parse(source : String) : Parsed | Array(String)
      root = begin
        JSON.parse(source)
      rescue ex : JSON::ParseException
        return ["file: not valid JSON (#{ex.message})"]
      end

      top = root.as_h?
      return ["file: must be a JSON object"] unless top

      problems = [] of String
      (top.keys - TOP_KEYS).sort.each { |k| problems << "#{k}: unknown key" }

      has_message = top.has_key?("message")
      has_notes = top.has_key?("notes")

      if has_message && has_notes
        problems << "file: give either message or notes, not both"
      elsif !has_message && !has_notes
        problems << "file: needs message or notes"
      end

      message = has_message ? non_empty_string(top["message"], "message", problems) : nil

      summary : String? = nil
      if top.has_key?("summary")
        if has_message
          problems << "summary: only allowed with notes"
        else
          summary = non_empty_string(top["summary"], "summary", problems)
        end
      end

      notes = has_notes ? parse_notes(top["notes"], problems) : [] of Note

      return problems unless problems.empty?
      Parsed.new(message: message, summary: summary, notes: notes)
    end

    private def self.parse_notes(value : JSON::Any, problems : Array(String)) : Array(Note)
      list = value.as_a?
      unless list
        problems << "notes: must be an array"
        return [] of Note
      end
      if list.empty?
        problems << "notes: must not be empty"
        return [] of Note
      end

      notes = [] of Note
      list.each_with_index do |item, i|
        path = "notes[#{i}]"
        entry = item.as_h?
        unless entry
          problems << "#{path}: must be an object"
          next
        end
        (entry.keys - NOTE_KEYS).sort.each { |k| problems << "#{path}.#{k}: unknown key" }

        quote = field(entry, "quote", path, problems)
        note = field(entry, "note", path, problems)
        notes << Note.new(quote, note) if quote && note
      end
      notes
    end

    private def self.field(entry : Hash(String, JSON::Any), key : String, path : String, problems : Array(String)) : String?
      unless entry.has_key?(key)
        problems << "#{path}.#{key}: missing"
        return nil
      end
      non_empty_string(entry[key], "#{path}.#{key}", problems)
    end

    private def self.non_empty_string(value : JSON::Any, path : String, problems : Array(String)) : String?
      str = value.as_s?
      if str.nil?
        problems << "#{path}: must be a string"
        nil
      elsif str.strip.empty?
        problems << "#{path}: must not be empty"
        nil
      else
        str
      end
    end
  end
end
