//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import WireDataModel
import WireUtilities


extension ConversationCell {
    static var allCellTypes: [ConversationCell.Type] = [
    TextMessageCell.self,
    ImageMessageCell.self,
    ConversationRenamedCell.self,
    PingCell.self,
    PerformedCallCell.self,
    MissedCallCell.self,
    ConnectionRequestCell.self,
    ConversationNewDeviceCell.self,
    ConversationVerifiedCell.self,
    MissingMessagesCell.self,
    ConversationIgnoredDeviceCell.self,
    CannotDecryptCell.self,
    FileTransferCell.self,
    VideoMessageCell.self,
    AudioMessageCell.self,
    ParticipantsCell.self,
    LocationMessageCell.self,
    MessageDeletedCell.self,
    UnknownMessageCell.self,
    MessageTimerUpdateCell.self
    ]
}

@objcMembers final class ConversationTableViewDataSource: NSObject {
    @objc public static let defaultBatchSize = 30 // Magic amount of messages per screen (upper bound)
    
    private var fetchController: NSFetchedResultsController<ZMMessage>!
    private var currentFetchLimit: Int = defaultBatchSize * 3 {
        didSet {
            createFetchController()
            tableView.reloadData()
        }
    }

    let conversation: ZMConversation
    let tableView: UITableView
    
    public var firstUnreadMessage: ZMConversationMessage?
    public var selectedMessage: ZMConversationMessage? = nil
    public var editingMessage: ZMConversationMessage? = nil {
        didSet {
            self.reconfigureVisibleCells(withDeleted: Set())
        }
    }
    
    public weak var conversationCellDelegate: ConversationCellDelegate? = nil
    
    public var searchQueries: [String] = []
    
    public var messages: [ZMConversationMessage] {
        return fetchController.fetchedObjects ?? []
    }
    
    public func moveUp(until message: ZMConversationMessage) {
        repeat {
            if let _ = index(of: message) {
                return
            }
        }
        while moveUp(by: 1000)
    }
    
    @discardableResult public func moveUp(by numberOfMessages: Int) -> Bool {
        guard let moc = conversation.managedObjectContext else {
            fatal("conversation.managedObjectContext == nil")
        }
        
        let fetchRequest = self.fetchRequest()
        let totalCount = try! moc.count(for: fetchRequest)
        
        guard currentFetchLimit < totalCount else {
            return false
        }
        
        currentFetchLimit = currentFetchLimit + numberOfMessages
        return true
    }
    
    @objc func indexOfMessage(_ message: ZMConversationMessage) -> Int {
        guard let index = index(of: message) else {
            return NSNotFound
        }
        return index
    }
    
    public func index(of message: ZMConversationMessage) -> Int? {
        if let indexPath = fetchController.indexPath(forObject: message as! ZMMessage) {
            return indexPath.row
        }
        else {
            return nil
        }
    }
    
    func configure(_ conversationCell: ConversationCell, with message: ZMConversationMessage, at index: Int)
    {
        // If a message has been deleted, we don't try to configure it
        guard !message.hasBeenDeleted else { return }
        
        let layoutProperties = self.layoutProperties(for: message, at: index)
    
        conversationCell.isSelected = (message == self.selectedMessage)
        conversationCell.beingEdited = (message == self.editingMessage)
        
        conversationCell.configure(for: message, layoutProperties: layoutProperties)
    }
    
    public func reconfigureVisibleCells(withDeleted deletedIndexes: Set<IndexPath>) {
        
        tableView.visibleCells.forEach { cell in
            guard let conversationCell = cell as? ConversationCell,
                  let indexPath = self.tableView.indexPath(for: cell),
                    !deletedIndexes.contains(indexPath) else {
                return
            }
            
            conversationCell.searchQueries = self.searchQueries
            self.configure(conversationCell, with: conversationCell.message, at: indexPath.row)
        }
    }

    fileprivate func stopAudioPlayer(for indexPath: IndexPath) {
        guard let audioTrackPlayer = AppDelegate.shared().mediaPlaybackManager?.audioTrackPlayer,
              let sourceMessage = audioTrackPlayer.sourceMessage,
              sourceMessage == self.messages[indexPath.row] else {
            return
        }
        
        audioTrackPlayer.stop()
    }
    
    private func fetchRequest() -> NSFetchRequest<ZMMessage> {
        let fetchRequest = NSFetchRequest<ZMMessage>(entityName: ZMMessage.entityName())
        fetchRequest.fetchBatchSize = type(of: self).defaultBatchSize
        fetchRequest.predicate = conversation.visibleMessagesPredicate
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(ZMMessage.serverTimestamp), ascending: false)]
        return fetchRequest
    }
    
    private func createFetchController() {
        let fetchRequest = self.fetchRequest()
        fetchRequest.fetchLimit = currentFetchLimit
        
        fetchController = NSFetchedResultsController<ZMMessage>(fetchRequest: fetchRequest,
                                                                managedObjectContext: conversation.managedObjectContext!,
                                                                sectionNameKeyPath: nil,
                                                                cacheName: nil)
        
        self.fetchController.delegate = self
        try! fetchController.performFetch()
    }
    
    init(conversation: ZMConversation, tableView: UITableView) {
        self.conversation = conversation
        self.tableView = tableView
        
        super.init()
        
        registerTableCellClasses()
        createFetchController()
    }
}

extension ConversationTableViewDataSource: NSFetchedResultsControllerDelegate {
    func controllerWillChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        tableView.beginUpdates()
    }
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>,
                    didChange anObject: Any,
                    at indexPath: IndexPath?,
                    for changeType: NSFetchedResultsChangeType,
                    newIndexPath: IndexPath?) {
        
        switch changeType {
        case .insert:
            guard let insertedIndexPath = newIndexPath else {
                fatal("Missing new index path")
            }
            
            tableView.insertRows(at: [insertedIndexPath], with: .fade)
        case .delete:
            guard let indexPathToRemove = indexPath else {
                fatal("Missing index path")
            }
            
            tableView.deleteRows(at: [indexPathToRemove], with: .fade)
            self.stopAudioPlayer(for: indexPathToRemove)
        case .update:
            guard let indexPathToUpdate = indexPath,
                  let message = anObject as? ZMMessage,
                  let loadedCell = tableView.cellForRow(at: indexPathToUpdate) as? ConversationCell else {
                return
            }
            
            loadedCell.configure(for: message, layoutProperties: loadedCell.layoutProperties)
            
        case .move:
            if let indexPath = indexPath {
                tableView.deleteRows(at: [indexPath], with: .fade)
            }
            
            if let newIndexPath = newIndexPath {
                tableView.insertRows(at: [newIndexPath], with: .fade)
            }
        }
    }
    
    func controller(_ controller: NSFetchedResultsController<NSFetchRequestResult>,
                    didChange sectionInfo: NSFetchedResultsSectionInfo,
                    atSectionIndex sectionIndex: Int,
                    for changeType: NSFetchedResultsChangeType) {
        let indexSet = IndexSet(integer: sectionIndex)
        
        switch changeType {
        case .delete:
            tableView.deleteSections(indexSet, with: .fade)
        case .update:
            tableView.reloadSections(indexSet, with: .fade)
        case .insert:
            tableView.insertSections(indexSet, with: .fade)
        case .move:
            fatal("Unexpected change type")
        }
    }
    
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
        tableView.endUpdates()
    }
    

}

extension ConversationTableViewDataSource {
    
    func registerTableCellClasses() {
        ConversationCell.allCellTypes.forEach {
            tableView.register($0, forCellReuseIdentifier: $0.reuseIdentifier)
        }
    }
}

extension ConversationTableViewDataSource: UITableViewDataSource {
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return messages.count
    }
    
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let message = messages[indexPath.row]
        
        let cell = tableView.dequeueReusableCell(withIdentifier: message.cellClass.reuseIdentifier, for: indexPath)
        guard let conversationCell = cell as? ConversationCell else { fatal("Unknown cell") }

        // Newly created cells will have a size of {320, 44}, which leads to layout problems when they contain `UICollectionViews`.
        // This is needed as long as `ParticipantsCell` contains a `UICollectionView`.
        var bounds = conversationCell.bounds
        bounds.size.width = tableView.bounds.size.width
        conversationCell.bounds = bounds
        
        conversationCell.searchQueries = searchQueries
        conversationCell.delegate = conversationCellDelegate
        // Configuration of the cell is not possible when `ZMUserSession` is not available.
        if let _ = ZMUserSession.shared() {
            configure(conversationCell, with: message, at: indexPath.row)
        }
        return conversationCell
    }
}

extension ZMConversationMessage {
    var cellClass: ConversationCell.Type {
        
        if isText {
            return TextMessageCell.self
        } else if isVideo {
            return VideoMessageCell.self
        } else if isAudio {
            return AudioMessageCell.self
        } else if isLocation {
            return LocationMessageCell.self
        } else if isFile {
            return FileTransferCell.self
        } else if isImage {
            return ImageMessageCell.self
        } else if isKnock {
            return PingCell.self
        } else if isSystem, let systemMessageType = systemMessageData?.systemMessageType {
            switch systemMessageType {
            case .connectionRequest:
                return ConnectionRequestCell.self
            case .conversationNameChanged:
                return ConversationRenamedCell.self
            case .missedCall:
                return MissedCallCell.self
            case .newClient, .usingNewDevice:
                return ConversationNewDeviceCell.self
            case .ignoredClient:
                return ConversationIgnoredDeviceCell.self
            case .conversationIsSecure:
                return ConversationVerifiedCell.self
            case .potentialGap, .reactivatedDevice:
                return MissingMessagesCell.self
            case .decryptionFailed, .decryptionFailed_RemoteIdentityChanged:
                return CannotDecryptCell.self
            case .participantsAdded, .participantsRemoved, .newConversation, .teamMemberLeave:
                return ParticipantsCell.self
            case .messageDeletedForEveryone:
                return MessageDeletedCell.self
            case .performedCall:
                return PerformedCallCell.self
            case .messageTimerUpdate:
                return MessageTimerUpdateCell.self
            default:
                fatal("Unknown cell")
            }
        } else {
            return UnknownMessageCell.self
        }
        
        fatal("Unknown cell")
    }
}
