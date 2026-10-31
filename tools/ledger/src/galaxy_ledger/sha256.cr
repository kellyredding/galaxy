module GalaxyLedger
  # SHA-256 through macOS's CommonCrypto, which ships inside libSystem.
  #
  # Crystal's Digest::SHA256 calls OpenSSL, which made this binary load
  # Homebrew's libcrypto by absolute path and fail to start on any Mac
  # without that exact Homebrew version installed.
  class SHA256
    lib LibCommonCrypto
      DIGEST_LENGTH = 32

      struct Context
        count : UInt32[2]
        hash : UInt32[8]
        wbuf : UInt32[16]
      end

      fun sha256_init = CC_SHA256_Init(c : Context*) : Int32
      fun sha256_update = CC_SHA256_Update(c : Context*, data : Void*, len : UInt32) : Int32
      fun sha256_final = CC_SHA256_Final(md : UInt8*, c : Context*) : Int32
    end

    # CC_SHA256_Update takes a 32-bit length, so input is fed in pieces.
    CHUNK = 1 << 30

    def self.hexdigest(data : String | Bytes) : String
      new.update(data).hexfinal
    end

    def initialize
      @context = LibCommonCrypto::Context.new
      LibCommonCrypto.sha256_init(pointerof(@context))
    end

    def update(data : String | Bytes) : self
      bytes = data.is_a?(String) ? data.to_slice : data
      offset = 0
      while offset < bytes.size
        n = Math.min(CHUNK, bytes.size - offset)
        LibCommonCrypto.sha256_update(pointerof(@context), (bytes + offset).to_unsafe, n.to_u32)
        offset += n
      end
      self
    end

    def hexfinal : String
      digest = Bytes.new(LibCommonCrypto::DIGEST_LENGTH)
      LibCommonCrypto.sha256_final(digest.to_unsafe, pointerof(@context))
      digest.hexstring
    end
  end
end
