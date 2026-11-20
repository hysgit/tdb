import AVFoundation
import Flutter
import Foundation
import Speech

/// File recognition only. All job state is confined to the main queue.
final class TdbSpeechBridge: NSObject, FlutterPlugin {
  private final class Job {
    let asset: AVURLAsset
    let recognizer: SFSpeechRecognizer
    let offline: Bool
    let requestedStart: Double
    let requestedEnd: Double?
    let reply: FlutterResult
    var directory: URL?
    var exporter: AVAssetExportSession?
    var speechTask: SFSpeechRecognitionTask?
    var timeout: DispatchWorkItem?
    var words: [[String: Any]] = []
    var cursor = 0.0
    var end = 0.0
    var cancelled = false
    var recognitionID: UUID?
    var cancellationReplies: [FlutterResult] = []

    init(asset: AVURLAsset, recognizer: SFSpeechRecognizer, offline: Bool,
         start: Double, end: Double?, reply: @escaping FlutterResult) {
      self.asset = asset
      self.recognizer = recognizer
      self.offline = offline
      self.requestedStart = start
      self.requestedEnd = end
      self.reply = reply
    }
  }

  private var current: Job?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tingdubao/speech_recognition",
                                       binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(TdbSpeechBridge(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { self.handle(call, result: result) }
      return
    }
    let arguments = call.arguments as? [String: Any] ?? [:]
    let locale = arguments["locale"] as? String ?? "en_US"
    switch call.method {
    case "locales":
      result(SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted())
    case "supportsOffline":
      result(SFSpeechRecognizer(locale: Locale(identifier: locale))?
        .supportsOnDeviceRecognition ?? false)
    case "cancel":
      if let job = current {
        job.cancellationReplies.append(result)
        job.cancelled = true
        if let exporter = job.exporter {
          // The export completion owns cleanup; do not remove a file still being written.
          exporter.cancelExport()
        } else {
          job.asset.cancelLoading()
          job.speechTask?.cancel()
          finish(job, error: error("cancelled", "已取消语音识别。"))
        }
      } else {
        result(nil)
      }
    case "transcribe":
      transcribe(arguments, locale: locale, reply: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func transcribe(_ arguments: [String: Any], locale: String,
                          reply: @escaping FlutterResult) {
    guard current == nil else {
      reply(error("busy", "已有语音识别正在进行，请先取消或等待完成。"))
      return
    }
    guard let path = arguments["path"] as? String,
          FileManager.default.isReadableFile(atPath: path) else {
      reply(error("invalid_file", "无法读取所选音视频文件。"))
      return
    }
    let start = (arguments["startMilliseconds"] as? NSNumber)?.doubleValue ?? 0
    let end = (arguments["endMilliseconds"] as? NSNumber)?.doubleValue
    guard start.isFinite, start >= 0,
          end == nil || (end!.isFinite && end! > start) else {
      reply(error("invalid_range", "识别结束时间须晚于开始时间。"))
      return
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
      reply(error("unsupported_locale", "系统不支持所选识别语言。"))
      return
    }
    let offline = arguments["offline"] as? Bool ?? true
    guard !offline || recognizer.supportsOnDeviceRecognition else {
      reply(error("offline_unavailable", "此设备或语言不支持离线语音识别，请选择可用语言或明确关闭离线选项。"))
      return
    }
    let job = Job(asset: AVURLAsset(url: URL(fileURLWithPath: path)),
                  recognizer: recognizer, offline: offline,
                  start: start / 1000, end: end.map { $0 / 1000 }, reply: reply)
    current = job
    // Capability queries never request authorization; only this user action does.
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard self.current === job else { return }
        guard status == .authorized else {
          self.finish(job, error: self.error("permission_denied", "请在系统设置中允许语音识别权限后重试。"))
          return
        }
        self.load(job)
      }
    }
  }

  private func load(_ job: Job) {
    job.asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) {
      DispatchQueue.main.async {
        guard self.current === job else { return }
        var loadingError: NSError?
        guard job.asset.statusOfValue(forKey: "duration", error: &loadingError) == .loaded,
              job.asset.statusOfValue(forKey: "tracks", error: &loadingError) == .loaded else {
          self.finish(job, error: self.error("invalid_media", "无法读取媒体时长或音轨。"))
          return
        }
        let duration = CMTimeGetSeconds(job.asset.duration)
        guard duration.isFinite, duration > 0,
              !job.asset.tracks(withMediaType: .audio).isEmpty else {
          self.finish(job, error: self.error("missing_audio", "所选文件没有可识别的音轨。"))
          return
        }
        job.cursor = job.requestedStart
        job.end = min(job.requestedEnd ?? duration, duration)
        guard job.cursor < job.end else {
          self.finish(job, error: self.error("invalid_range", "识别区间超出了媒体长度。"))
          return
        }
        do {
          let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tdb-speech-\(UUID().uuidString)", isDirectory: true)
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          job.directory = directory
          self.exportNext(job)
        } catch {
          self.finish(job, error: self.error("temporary_file_failed", "无法创建识别临时文件。"))
        }
      }
    }
  }

  private func exportNext(_ job: Job) {
    guard current === job else { return }
    if job.cancelled {
      finish(job, error: error("cancelled", "已取消语音识别。"))
      return
    }
    guard job.cursor < job.end else {
      finish(job)
      return
    }
    guard let directory = job.directory,
          let exporter = AVAssetExportSession(asset: job.asset,
                                               presetName: AVAssetExportPresetAppleM4A) else {
      finish(job, error: error("export_unavailable", "此媒体无法转换为识别所需的音频。"))
      return
    }
    let offset = job.cursor
    let length = min(45, job.end - offset)
    let file = directory.appendingPathComponent("\(UUID().uuidString).m4a")
    exporter.outputURL = file
    exporter.outputFileType = .m4a
    exporter.timeRange = CMTimeRange(start: CMTime(seconds: offset, preferredTimescale: 600),
                                     duration: CMTime(seconds: length, preferredTimescale: 600))
    job.exporter = exporter
    exporter.exportAsynchronously {
      DispatchQueue.main.async {
        guard self.current === job else { return }
        job.exporter = nil
        if job.cancelled {
          self.finish(job, error: self.error("cancelled", "已取消语音识别。"))
          return
        }
        guard exporter.status == .completed else {
          self.finish(job, error: self.error("export_failed", "识别音频切片失败，请检查媒体文件。"))
          return
        }
        self.recognize(job, file: file, offset: offset, length: length)
      }
    }
  }

  private func recognize(_ job: Job, file: URL, offset: Double, length: Double) {
    guard current === job else { return }
    guard !job.offline || job.recognizer.supportsOnDeviceRecognition else {
      finish(job, error: error("offline_unavailable", "离线识别当前不可用，未将音频发送到网络。"))
      return
    }
    guard job.recognizer.isAvailable else {
      finish(job, error: error("recognizer_unavailable", "系统语音识别当前不可用，请稍后重试。"))
      return
    }
    let request = SFSpeechURLRecognitionRequest(url: file)
    request.requiresOnDeviceRecognition = job.offline
    request.shouldReportPartialResults = false
    let recognitionID = UUID()
    job.recognitionID = recognitionID
    let timeout = DispatchWorkItem {
      guard self.current === job, job.recognitionID == recognitionID else { return }
      job.speechTask?.cancel()
      self.finish(job, error: self.error("recognition_timeout", "系统语音识别超时，请重试较短片段。"))
    }
    job.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
    job.speechTask = job.recognizer.recognitionTask(with: request) { result, recognitionError in
      DispatchQueue.main.async {
        guard self.current === job, job.recognitionID == recognitionID else { return }
        if let result = result, result.isFinal {
          job.timeout?.cancel()
          job.timeout = nil
          job.recognitionID = nil
          job.speechTask = nil
          for segment in result.bestTranscription.segments {
            let start = offset + segment.timestamp
            let end = min(offset + length, start + segment.duration)
            guard start.isFinite, end.isFinite, start >= offset, end > start else { continue }
            job.words.append(["text": segment.substring, "timestamp": start,
                              "duration": end - start, "confidence": Double(segment.confidence)])
          }
          do {
            try FileManager.default.removeItem(at: file)
          } catch {
            self.finish(job, error: self.error("cleanup_failed", "识别临时文件清理失败，请重试。"))
            return
          }
          job.cursor = offset + length
          // Avoid an unexportable sub-millisecond tail from floating-point arithmetic.
          if job.end - job.cursor < 0.001 { job.cursor = job.end }
          self.exportNext(job)
        } else if recognitionError != nil {
          self.finish(job, error: self.error("recognition_failed", "系统未能完成语音识别，请检查语言、离线可用性和音频内容。"))
        }
      }
    }
  }

  private func finish(_ job: Job, error failure: FlutterError? = nil) {
    guard current === job else { return }
    // Export callbacks must have completed before this method may remove their directory.
    assert(job.exporter == nil)
    job.timeout?.cancel()
    job.timeout = nil
    job.recognitionID = nil
    job.speechTask?.cancel()
    job.speechTask = nil
    var finalFailure = failure
    if let directory = job.directory {
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        if finalFailure == nil {
          finalFailure = self.error("cleanup_failed", "识别临时文件清理失败，请重试。")
        }
      }
    }
    current = nil
    if let failure = finalFailure {
      job.reply(failure)
    } else {
      job.reply(["words": job.words, "locale": job.recognizer.locale.identifier,
                 "offline": job.offline])
    }
    for reply in job.cancellationReplies { reply(nil) }
    job.cancellationReplies.removeAll()
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}
