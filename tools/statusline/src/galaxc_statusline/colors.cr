module GalaxcStatusline
  module Colors
    RESET = "\e[0m"

    ANSI_CODES = {
      "red"            => "\e[31m",
      "green"          => "\e[32m",
      "yellow"         => "\e[33m",
      "blue"           => "\e[34m",
      "magenta"        => "\e[35m",
      "cyan"           => "\e[36m",
      "white"          => "\e[37m",
      "bright_red"     => "\e[91m",
      "bright_green"   => "\e[92m",
      "bright_yellow"  => "\e[93m",
      "bright_blue"    => "\e[94m",
      "bright_magenta" => "\e[95m",
      "bright_cyan"    => "\e[96m",
      "bright_white"   => "\e[97m",
      "default"        => "",
    }

    BOLD = "\e[1m"

    def self.colorize(text : String, color_spec : String) : String
      return text if color_spec == "default" || color_spec.empty?

      # Handle bold: prefix
      if color_spec.starts_with?("bold:")
        color_name = color_spec[5..]
        code = ANSI_CODES[color_name]? || ""
        return "#{BOLD}#{code}#{text}#{RESET}"
      end

      code = ANSI_CODES[color_spec]? || ""
      return text if code.empty?

      "#{code}#{text}#{RESET}"
    end
  end
end
