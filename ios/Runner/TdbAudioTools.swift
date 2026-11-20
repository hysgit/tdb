import AudioToolbox
import AVFoundation
import Flutter
import Foundation

/// Offline audio extraction/retiming. Mutable state and sample pumping share one queue.
final class TdbAudioTools: NSObject, FlutterPlugin {
  private final class Job {
    let id = UUID().uuidString
    let asset: AVURLAsset
    let speed: Double
    let format: String
    let bitrate: Int
    let reply: FlutterResult
    var directory: URL?
    var file: URL?
    var reader: AVAssetReader?
    var writer: AVAssetWriter?
    var output: AVAssetReaderAudioMixOutput?
    var input: AVAssetWriterInput?
    var validator: AVURLAsset?
    var expectedDuration = 0.0
    var finishing = false
    var cancelled = false
    var cancellationReplies: [FlutterResult] = []

    init(path: String, speed: Double, format: String, bitrate: Int, reply: @escaping FlutterResult) {
      asset = AVURLAsset(url: URL(fileURLWithPath: path))
      self.speed = speed
      self.format = format
      self.bitrate = bitrate
      self.reply = reply
    }
  }

  private let queue = DispatchQueue(label: "tingdubao.audio-tools", qos: .userInitiated)
  private var current: Job?
  private var prepared: [String: URL] = [:]

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tingdubao/audio_tools", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TdbAudioTools(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    queue.async {
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "prepare":
        self.start(args, reply: result)
      case "cancel":
        guard let job = self.current else { self.reply(result, nil); return }
        job.cancellationReplies.append(result)
        job.cancelled = true
        job.asset.cancelLoading()
        job.validator?.cancelLoading()
        job.reader?.cancelReading()
        // Apple's cancelWriting blocks until writing has actually stopped.
        job.writer?.cancelWriting()
        if !job.finishing { self.fail(job, "cancelled", "已取消音频处理。") }
      case "release":
        guard let id = args["id"] as? String, let directory = self.prepared[id] else {
          self.reply(result, nil); return
        }
        do {
          try FileManager.default.removeItem(at: directory)
          self.prepared.removeValue(forKey: id)
          self.reply(result, nil)
        } catch {
          self.reply(result, FlutterError(code: "cleanup_failed", message: "临时音频清理失败。", details: nil))
        }
      case "verifyMp3":
        guard let id = args["id"] as? String, let directory = self.prepared[id],
              let expected = (args["duration"] as? NSNumber)?.doubleValue,
              expected.isFinite, expected > 0 else {
          self.reply(result, FlutterError(code: "invalid_output", message: "MP3 验证参数无效。", details: nil)); return
        }
        let asset = AVURLAsset(url: directory.appendingPathComponent("audio.mp3"))
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
          self.queue.async {
            var error: NSError?
            let seconds = CMTimeGetSeconds(asset.duration)
            let descriptions = asset.tracks(withMediaType: .audio).first?.formatDescriptions as? [CMFormatDescription] ?? []
            guard asset.statusOfValue(forKey: "duration", error: &error) == .loaded,
                  asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
                  seconds.isFinite, seconds > 0,
                  abs(seconds - expected) <= max(0.15, expected * 0.02),
                  descriptions.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEGLayer3 }) else {
              self.reply(result, FlutterError(code: "invalid_output", message: "MP3 编码或时长未通过系统验证。", details: nil)); return
            }
            self.reply(result, nil)
          }
        }
      default:
        self.reply(result, FlutterMethodNotImplemented)
      }
    }
  }

  private func start(_ args: [String: Any], reply: @escaping FlutterResult) {
    guard current == nil else {
      self.reply(reply, FlutterError(code: "busy", message: "已有音频处理正在进行。", details: nil)); return
    }
    guard let path = args["path"] as? String, FileManager.default.isReadableFile(atPath: path),
          let speed = (args["speed"] as? NSNumber)?.doubleValue, speed.isFinite, (0.1...5).contains(speed),
          let format = args["format"] as? String, ["m4a", "wav"].contains(format),
          let bitrate = args["bitrate"] as? Int, [96, 128, 192].contains(bitrate) else {
      self.reply(reply, FlutterError(code: "invalid_input", message: "请选择有效文件、速度和输出格式。", details: nil)); return
    }
    let job = Job(path: path, speed: speed, format: format, bitrate: bitrate, reply: reply)
    current = job
    job.asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
      self.queue.async {
        guard self.current === job else { return }
        var error: NSError?
        guard job.asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
              let source = job.asset.tracks(withMediaType: .audio).first else {
          self.fail(job, "missing_audio", "文件中没有可读取的音轨。"); return
        }
        self.configure(job, source: source)
      }
    }
  }

  private func configure(_ job: Job, source: AVAssetTrack) {
    do {
      let composition = AVMutableComposition()
      guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else {
        fail(job, "unsupported_audio", "无法创建音频处理轨道。"); return
      }
      let range = source.timeRange
      let seconds = CMTimeGetSeconds(range.duration)
      guard seconds.isFinite, seconds > 0 else { fail(job, "invalid_media", "音轨时长无效。"); return }
      job.expectedDuration = seconds / job.speed
      // RIFF/WAV has a 32-bit data-size field. Refuse instead of truncating long PCM.
      if job.format == "wav" && job.expectedDuration * 44100 * 4 > 4_000_000_000 {
        fail(job, "too_large", "音频过长，无法生成 MP3 所需的中间 WAV，请先选择较短文件。"); return
      }
      try track.insertTimeRange(range, of: source, at: .zero)
      track.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                           toDuration: CMTime(seconds: job.expectedDuration, preferredTimescale: 600))
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tdb-audio-\(job.id)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      job.directory = directory
      let file = directory.appendingPathComponent("audio.\(job.format)")
      job.file = file
      let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM,
                               AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                               AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                               AVLinearPCMIsBigEndianKey: false,
                               AVLinearPCMIsNonInterleaved: false]
      var readerSettings = pcm
      readerSettings[AVLinearPCMIsNonInterleaved] = false
      let reader = try AVAssetReader(asset: composition)
      let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: readerSettings)
      output.audioTimePitchAlgorithm = .spectral
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else { fail(job, "reader_unavailable", "系统不支持读取此音轨。"); return }
      reader.add(output)
      let writer = try AVAssetWriter(outputURL: file, fileType: job.format == "wav" ? .wav : .m4a)
      let settings: [String: Any] = job.format == "wav" ? pcm : [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
        AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: job.bitrate * 1000,
      ]
      guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
        fail(job, "encoder_unavailable", "系统不支持所选音频编码设置。"); return
      }
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      input.expectsMediaDataInRealTime = false
      guard writer.canAdd(input) else { fail(job, "writer_unavailable", "无法创建音频输出。"); return }
      writer.add(input)
      job.reader = reader; job.writer = writer; job.output = output; job.input = input
      guard writer.startWriting(), reader.startReading() else {
        fail(job, "start_failed", "音频处理无法启动。"); return
      }
      writer.startSession(atSourceTime: .zero)
      pump(job)
    } catch {
      fail(job, "prepare_failed", "无法准备音轨或临时输出文件。")
    }
  }

  private func pump(_ job: Job) {
    guard current === job, !job.cancelled, !job.finishing,
          let reader = job.reader, let writer = job.writer,
          let input = job.input, let output = job.output else { return }
    // Yield between batches so cancellation is not starved by a fast producer.
    for _ in 0..<32 {
      guard input.isReadyForMoreMediaData else { break }
      let appended: Bool? = autoreleasepool {
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        return input.append(sample)
      }
      if appended == nil {
        guard reader.status == .completed else { fail(job, "read_failed", "读取音轨失败。"); return }
        input.markAsFinished()
        job.finishing = true
        writer.finishWriting {
          self.queue.async {
            guard self.current === job else { return }
            job.finishing = false
            if job.cancelled { self.fail(job, "cancelled", "已取消音频处理。"); return }
            guard writer.status == .completed else { self.fail(job, "write_failed", "音频编码失败。"); return }
            self.validate(job)
          }
        }
        return
      }
      if appended == false { fail(job, "write_failed", "写入音频失败。"); return }
    }
    guard writer.status == .writing, (reader.status == .reading || reader.status == .completed) else {
      fail(job, "processing_failed", "音频处理被系统中止。"); return
    }
    queue.asyncAfter(deadline: .now() + 0.005) { self.pump(job) }
  }

  private func validate(_ job: Job) {
    guard let file = job.file else { fail(job, "invalid_output", "没有生成输出音频。"); return }
    let asset = AVURLAsset(url: file)
    job.validator = asset
    asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
      self.queue.async {
        guard self.current === job else { return }
        var error: NSError?
        guard asset.statusOfValue(forKey: "duration", error: &error) == .loaded,
              asset.statusOfValue(forKey: "tracks", error: &error) == .loaded,
              let track = asset.tracks(withMediaType: .audio).first else {
          self.fail(job, "invalid_output", "输出音频无法通过系统读取验证。"); return
        }
        let seconds = CMTimeGetSeconds(asset.duration)
        let descriptions = track.formatDescriptions as! [CMFormatDescription]
        let expected: FourCharCode = job.format == "wav" ? kAudioFormatLinearPCM : kAudioFormatMPEG4AAC
        guard seconds.isFinite, seconds > 0,
              abs(seconds - job.expectedDuration) <= max(0.5, job.expectedDuration * 0.03),
              descriptions.contains(where: { CMFormatDescriptionGetMediaSubType($0) == expected }) else {
          self.fail(job, "invalid_output", "输出编码或变速后的时长验证失败。"); return
        }
        self.prepared[job.id] = job.directory
        self.current = nil
        self.reply(job.reply, ["id": job.id, "path": file.path, "duration": seconds,
                               "format": job.format, "sampleRate": 44100, "channels": 2])
      }
    }
  }

  private func fail(_ job: Job, _ code: String, _ message: String) {
    guard current === job else { return }
    job.reader?.cancelReading()
    job.writer?.cancelWriting()
    var failure = FlutterError(code: code, message: message, details: nil)
    if let directory = job.directory {
      do { try FileManager.default.removeItem(at: directory) }
      catch { failure = FlutterError(code: "cleanup_failed", message: "处理失败，临时文件清理也未完成。", details: nil) }
    }
    current = nil
    reply(job.reply, failure)
    for callback in job.cancellationReplies { reply(callback, nil) }
    job.cancellationReplies.removeAll()
  }

  private func reply(_ callback: @escaping FlutterResult, _ value: Any?) {
    DispatchQueue.main.async { callback(value) }
  }
}
