import FluidAudio
import Foundation

/// Assigns each ASR word to the diarization speaker turn it overlaps, then
/// groups consecutive same-speaker words into segments. Gaps between turns
/// (silence, VAD-trimmed audio) fall back to the nearest turn by distance so
/// no word is ever dropped.
func mergeWordsWithSpeakers(
    words: [WordTiming],
    speakerTurns: [TimedSpeakerSegment]
) -> [AsrSegment] {
    guard !speakerTurns.isEmpty else {
        guard !words.isEmpty else { return [] }
        let text = words.map(\.word).joined(separator: " ")
        return [AsrSegment(start: words[0].startTime, end: words[words.count - 1].endTime, speaker: nil, text: text)]
    }

    let sortedTurns = speakerTurns.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

    func speaker(forMidpoint midpoint: Double) -> String {
        if let hit = sortedTurns.first(where: {
            midpoint >= Double($0.startTimeSeconds) && midpoint < Double($0.endTimeSeconds)
        }) {
            return hit.speakerId
        }
        // No turn covers this instant (gap/silence) - snap to whichever
        // turn's edge is closest in time.
        let nearest = sortedTurns.min { a, b in
            distance(midpoint, Double(a.startTimeSeconds), Double(a.endTimeSeconds))
                < distance(midpoint, Double(b.startTimeSeconds), Double(b.endTimeSeconds))
        }
        return nearest?.speakerId ?? "SPEAKER_00"
    }

    var segments: [AsrSegment] = []
    var currentSpeaker: String?
    var currentStart: Double = 0
    var currentEnd: Double = 0
    var currentWords: [String] = []

    func flush() {
        guard let speaker = currentSpeaker, !currentWords.isEmpty else { return }
        segments.append(
            AsrSegment(start: currentStart, end: currentEnd, speaker: speaker, text: currentWords.joined(separator: " "))
        )
    }

    for word in words {
        let midpoint = (word.startTime + word.endTime) / 2
        let speaker = speaker(forMidpoint: midpoint)

        if speaker != currentSpeaker {
            flush()
            currentSpeaker = speaker
            currentStart = word.startTime
            currentWords = []
        }
        currentEnd = word.endTime
        currentWords.append(word.word)
    }
    flush()

    return segments
}

private func distance(_ point: Double, _ start: Double, _ end: Double) -> Double {
    if point < start { return start - point }
    if point > end { return point - end }
    return 0
}
