import Foundation

/// One recognized word (or a short segment) with its place in the video, seconds.
struct GGSubtitleWord: Equatable {
    var text: String
    var start: Double
    var duration: Double

    var end: Double {
        return self.start + self.duration
    }
}

/// One line shown over the video.
struct GGSubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

struct GGSubtitleTrack: Equatable {
    var cues: [GGSubtitleCue]
    /// Telegram transcription has no timings: the lines are spread over the audio by length.
    var isTimingEstimated: Bool

    /// Index of the cue shown at `time`, if any. Binary search: cues are sorted and do not overlap.
    func cueIndex(at time: Double) -> Int? {
        var lower = 0
        var upper = self.cues.count - 1
        while lower <= upper {
            let middle = (lower + upper) / 2
            let cue = self.cues[middle]
            if time < cue.start {
                upper = middle - 1
            } else if time >= cue.end {
                lower = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    /// The next moment after `time` at which the shown line changes (a start or an end).
    func nextBoundary(after time: Double) -> Double? {
        if let index = self.cueIndex(at: time) {
            return self.cues[index].end
        }
        for cue in self.cues where cue.start > time {
            return cue.start
        }
        return nil
    }
}

enum GGSubtitleCueBuilder {
    static let maximumCharacters = 42
    static let maximumDuration: Double = 5.0
    static let pauseBreak: Double = 0.65
    static let minimumDuration: Double = 0.4

    /// Groups words into lines: a new line at a sentence end, after a pause, or when the line would
    /// get longer than `maximumCharacters` / `maximumDuration`.
    static func cues(words: [GGSubtitleWord], mediaDuration: Double?) -> [GGSubtitleCue] {
        var result: [GGSubtitleCue] = []
        var currentText = ""
        var currentStart: Double = 0.0
        var currentEnd: Double = 0.0
        var previousEnd: Double?

        func flush() {
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                result.append(GGSubtitleCue(start: currentStart, end: max(currentEnd, currentStart + minimumDuration), text: text))
            }
            currentText = ""
        }

        for word in words {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                continue
            }
            if !currentText.isEmpty {
                let candidateLength = currentText.count + 1 + text.count
                let pause = previousEnd.map { word.start - $0 } ?? 0.0
                if candidateLength > maximumCharacters || word.end - currentStart > maximumDuration || pause > pauseBreak {
                    flush()
                }
            }
            if currentText.isEmpty {
                currentText = text
                currentStart = word.start
            } else {
                currentText += " " + text
            }
            currentEnd = word.end
            previousEnd = word.end
            if let last = text.last, ".!?…".contains(last) {
                flush()
            }
        }
        flush()

        // No overlaps, nothing past the end of the video.
        for i in 0 ..< result.count {
            if i + 1 < result.count, result[i].end > result[i + 1].start {
                result[i].end = max(result[i].start + 0.05, result[i + 1].start)
            }
            if let mediaDuration = mediaDuration, mediaDuration > 0.0, result[i].end > mediaDuration {
                result[i].end = max(result[i].start + 0.05, mediaDuration)
            }
        }
        return result
    }

    /// Words of a plain text spread over `duration`, weighted by their length (Telegram transcription).
    static func estimatedWords(text: String, duration: Double) -> [GGSubtitleWord] {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        if tokens.isEmpty || duration <= 0.0 {
            return []
        }
        let totalWeight = tokens.reduce(0.0) { $0 + Double($1.count + 1) }
        var result: [GGSubtitleWord] = []
        var position: Double = 0.0
        for token in tokens {
            let length = duration * Double(token.count + 1) / totalWeight
            result.append(GGSubtitleWord(text: token, start: position, duration: length))
            position += length
        }
        return result
    }
}
