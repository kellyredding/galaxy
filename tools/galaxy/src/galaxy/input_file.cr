require "json"

module Galaxy
  # The file a driver hands `galaxy session send`: plain text, or notes that
  # answer quoted text. Strict, so a typo fails loudly instead of silently
  # dropping what the driver meant to say.
  module InputFile
    record Note, quote : String, note : String

    record Parsed, id : String, message : String?, summary : String?, notes : Array(Note) do
      def note_count : Int32
        notes.size
      end

      # The validated input as the `session.send` request carries it.
      def to_detail : Hash(String, JSON::Any)
        detail = {"id" => JSON::Any.new(id)}
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
        {"id": "lead-0007", "message": "Plain text, any length."}
        {"id": "lead-0008", "summary": "Optional overall comment.",
         "notes": [{"quote": "text being answered", "note": "the reply"}]}
      id: 1-128 characters of A-Z a-z 0-9 . _ : -, unique per session.
      Resend the same file to retry: Galaxy recognises the id.
      SHAPES

    TOP_KEYS  = %w[id message summary notes]
    NOTE_KEYS = %w[quote note]
    ID_FORMAT = /\A[A-Za-z0-9._:\-]{1,128}\z/

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

      id = parse_id(top, problems)

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

      return problems unless problems.empty? && (valid_id = id)
      Parsed.new(id: valid_id, message: message, summary: summary, notes: notes)
    end

    private def self.parse_id(top : Hash(String, JSON::Any), problems : Array(String)) : String?
      unless top.has_key?("id")
        problems << "id: missing"
        return nil
      end
      id = top["id"].as_s?
      if id.nil?
        problems << "id: must be a string"
        nil
      elsif !id.matches?(ID_FORMAT)
        problems << "id: must be 1-128 characters of A-Z a-z 0-9 . _ : -"
        nil
      else
        id
      end
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
