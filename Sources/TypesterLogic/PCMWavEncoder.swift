import Foundation

/// Wraps raw PCM s16le mono samples in a minimal RIFF/WAVE container.
public enum PCMWavEncoder {
    public static func wavData(pcm: Data, sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(pcm.count)
        let riffSize = UInt32(36 + pcm.count)

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(contentsOf: withUnsafeBytes(of: riffSize.littleEndian, Array.init))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian, Array.init)) // PCM fmt chunk size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init)) // PCM format
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt32(byteRate).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt16(blockAlign).littleEndian, Array.init))
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian, Array.init))
        header.append(contentsOf: Array("data".utf8))
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian, Array.init))
        header.append(pcm)
        return header
    }
}
