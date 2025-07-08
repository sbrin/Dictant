//
//  Item.swift
//  telly
//
//  Created by Mihail Ilin on 08.07.2025.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
