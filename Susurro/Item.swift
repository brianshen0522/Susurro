//
//  Item.swift
//  Susurro
//
//  Created by Brian Shen on 2026/7/14.
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
