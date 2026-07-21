//
//  DictantTests.swift
//  DictantTests
//
//  Created by Mihail Ilin on 08.07.2025.
//

import Testing
@testable import Dictant

struct DictantTests {

    @Test func filtersModelsToChatCompletionOptions() {
        let identifiers = [
            "gpt-5.6-sol",
            "gpt-4o-mini-transcribe",
            "text-embedding-3-small",
            "o3",
            "gpt-image-1",
            "gpt-4.1-mini",
            "gpt-5.6-sol"
        ]

        let result = SimpleSpeechService.chatCompletionModelIDs(from: identifiers)

        #expect(result == ["gpt-4.1-mini", "gpt-5.6-sol", "o3"])
    }

}
