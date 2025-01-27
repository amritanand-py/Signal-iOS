//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import SignalMessaging
import SignalRingRTC

// MARK: - CallCellDelegate

private protocol CallCellDelegate: AnyObject {
    func joinCall(from viewModel: CallsListViewController.CallViewModel)
    func returnToCall(from viewModel: CallsListViewController.CallViewModel)
    func showCallInfo(from viewModel: CallsListViewController.CallViewModel)
}

// MARK: - CallsListViewController

class CallsListViewController: OWSViewController, HomeTabViewController, CallServiceObserver {
    private typealias DiffableDataSource = UITableViewDiffableDataSource<Section, CallViewModel.ID>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<Section, CallViewModel.ID>

    // MARK: - Dependencies

    private struct Dependencies {
        let callService: CallService
        let callRecordQuerier: CallRecordQuerier
        let callRecordStore: CallRecordStore
        let contactsManager: ContactsManagerProtocol
        let db: SDSDatabaseStorage
        let fullTextSearchFinder: CallRecordLoader.Shims.FullTextSearchFinder
        let interactionStore: InteractionStore
        let threadStore: ThreadStore
    }

    private lazy var deps: Dependencies = Dependencies(
        callService: NSObject.callService,
        callRecordQuerier: DependenciesBridge.shared.callRecordQuerier,
        callRecordStore: DependenciesBridge.shared.callRecordStore,
        contactsManager: NSObject.contactsManager,
        db: NSObject.databaseStorage,
        fullTextSearchFinder: CallRecordLoader.Wrappers.FullTextSearchFinder(),
        interactionStore: DependenciesBridge.shared.interactionStore,
        threadStore: DependenciesBridge.shared.threadStore
    )

    private enum Constants {
        /// The max number of records to request when loading a new page of
        /// calls.
        static let pageSizeToLoad: UInt = 50

        /// The maximum number of calls this view should hold in-memory at once.
        /// Any calls beyond this number are dropped when loading new ones.
        static let maxCallsToHoldAtOnce: Int = 150
    }

    // MARK: - Lifecycle

    private var logger: PrefixedLogger = PrefixedLogger(prefix: "[CallsListVC]")

    private lazy var emptyStateMessageView: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        return label
    }()

    private lazy var noSearchResultsView: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .dynamicTypeBody
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        navigationItem.titleView = tabPicker
        updateBarButtonItems()

        let searchController = UISearchController(searchResultsController: nil)
        navigationItem.searchController = searchController
        searchController.searchResultsUpdater = self

        view.addSubview(tableView)
        tableView.autoPinEdgesToSuperviewEdges()
        tableView.delegate = self
        tableView.allowsSelectionDuringEditing = true
        tableView.allowsMultipleSelectionDuringEditing = true
        tableView.separatorStyle = .none
        tableView.contentInset = .zero
        tableView.register(CallCell.self, forCellReuseIdentifier: Self.callCellReuseIdentifier)
        tableView.dataSource = dataSource

        // [CallsTab] TODO: Remove when releasing
        let internalReminder = ReminderView(
            style: .warning,
            text: "The calls tab is internal-only. Some features are not yet implemented."
        )
        // tableHeaderView doesn't like autolayout. I'm sure I could get it to
        // work but it's internal anyway so I'm not gonna bother.
        internalReminder.frame.height = 100
        tableView.tableHeaderView = internalReminder

        view.addSubview(emptyStateMessageView)
        emptyStateMessageView.autoCenterInSuperview()

        view.addSubview(noSearchResultsView)
        noSearchResultsView.autoPinWidthToSuperviewMargins()
        noSearchResultsView.autoPinEdge(toSuperviewMargin: .top, withInset: 80)

        applyTheme()
        attachSelfAsObservers()

        loadCallRecordsAnew(animated: false)
    }

    override func themeDidChange() {
        super.themeDidChange()
        applyTheme()
        reloadAllRows()
    }

    private func updateBarButtonItems() {
        if tableView.isEditing {
            navigationItem.leftBarButtonItem = cancelMultiselectButton()
            navigationItem.rightBarButtonItem = nil
        } else {
            navigationItem.leftBarButtonItem = profileBarButtonItem()
            navigationItem.rightBarButtonItem = newCallButton()
        }
    }

    private func applyTheme() {
        view.backgroundColor = Theme.backdropColor
        tableView.backgroundColor = Theme.backgroundColor
    }

    // MARK: Profile button

    private func profileBarButtonItem() -> UIBarButtonItem {
        createSettingsBarButtonItem(
            databaseStorage: databaseStorage,
            actions: { settingsAction in
                [
                    .init(
                        title: "Select", // [CallsTab] TODO: Localize
                        image: Theme.iconImage(.contextMenuSelect),
                        attributes: []
                    ) { [weak self] _ in
                        self?.startMultiselect()
                    },
                    settingsAction,
                ]
            },
            showAppSettings: { [weak self] in
                self?.showAppSettings()
            }
        )
    }

    private func showAppSettings() {
        AssertIsOnMainThread()

        conversationSplitViewController?.selectedConversationViewController?.dismissMessageContextMenu(animated: true)
        presentFormSheet(AppSettingsViewController.inModalNavigationController(), animated: true)
    }

    private func startMultiselect() {
        Logger.debug("Select calls")
        // Swipe actions count as edit mode, so cancel those
        // before entering multiselection editing mode.
        tableView.setEditing(false, animated: true)
        tableView.setEditing(true, animated: true)
        updateBarButtonItems()
        showToolbar()
    }

    private var multiselectToolbarContainer: BlurredToolbarContainer?
    private var multiselectToolbar: UIToolbar? {
        multiselectToolbarContainer?.toolbar
    }

    private func showToolbar() {
        guard let tabController = tabBarController as? HomeTabBarController else { return }

        let toolbarContainer = BlurredToolbarContainer()
        toolbarContainer.alpha = 0
        view.addSubview(toolbarContainer)
        toolbarContainer.autoPinWidthToSuperview()
        toolbarContainer.autoPinEdge(toSuperviewEdge: .bottom)
        self.multiselectToolbarContainer = toolbarContainer

        tabController.setTabBarHidden(true, animated: true, duration: 0.1) { _ in
            // See ChatListViewController.showToolbar for why this is async
            DispatchQueue.main.async {
                self.updateMultiselectToolbarButtons()
            }
            UIView.animate(withDuration: 0.25) {
                toolbarContainer.alpha = 1
            } completion: { _ in
                self.tableView.contentSize.height += toolbarContainer.height
            }
        }
    }

    private func updateMultiselectToolbarButtons() {
        guard let multiselectToolbar else { return }

        let selectedRows = tableView.indexPathsForSelectedRows ?? []
        let areAllEntriesSelected = selectedRows.count == tableView.numberOfRows(inSection: 0)
        let hasSelectedEntries = !selectedRows.isEmpty

        let selectAllButtonTitle = areAllEntriesSelected ? "Deselect all" : "Select all" // [CallsTab] TODO: Localize
        let selectAllButton = UIBarButtonItem(
            title: selectAllButtonTitle,
            style: .plain,
            target: self,
            action: #selector(selectAllCalls)
        )

        let deleteButton = UIBarButtonItem(
            title: CommonStrings.deleteButton,
            style: .plain,
            target: self,
            action: #selector(deleteSelectedCalls)
        )
        deleteButton.isEnabled = hasSelectedEntries

        let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        multiselectToolbar.setItems(
            [selectAllButton, spacer, deleteButton],
            animated: false
        )
    }

    @objc
    private func selectAllCalls() {
        let selectedRows = tableView.indexPathsForSelectedRows ?? []
        let numberOfRows = tableView.numberOfRows(inSection: 0)
        let areAllEntriesSelected = selectedRows.count == numberOfRows

        if areAllEntriesSelected {
            selectedRows.forEach { tableView.deselectRow(at: $0, animated: false) }
        } else {
            (0..<numberOfRows)
                .lazy
                .map { .indexPathForPrimarySection(row: $0) }
                .forEach { tableView.selectRow(at: $0, animated: false, scrollPosition: .none) }
        }
        updateMultiselectToolbarButtons()
    }

    @objc
    private func deleteSelectedCalls() {
        Logger.debug("Detele selected calls")
    }

    // MARK: New call button

    private func newCallButton() -> UIBarButtonItem {
        let barButtonItem = UIBarButtonItem(
            image: Theme.iconImage(.buttonNewCall),
            style: .plain,
            target: self,
            action: #selector(newCall)
        )
        // [CallsTab] TODO: Accessibility label
        return barButtonItem
    }

    @objc
    private func newCall() {
        Logger.debug("New call")
        let viewController = NewCallViewController()
        let modal = OWSNavigationController(rootViewController: viewController)
        self.navigationController?.presentFormSheet(modal, animated: true)
    }

    // MARK: Cancel multiselect button

    private func cancelMultiselectButton() -> UIBarButtonItem {
        let barButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelMultiselect),
            accessibilityIdentifier: CommonStrings.cancelButton
        )
        return barButtonItem
    }

    @objc
    private func cancelMultiselect() {
        Logger.debug("Cancel selecting calls")
        tableView.setEditing(false, animated: true)
        updateBarButtonItems()
        hideToolbar()
    }

    private func hideToolbar() {
        guard let multiselectToolbarContainer else { return }
        UIView.animate(withDuration: 0.25) {
            multiselectToolbarContainer.alpha = 0
            self.tableView.contentSize.height = self.tableView.sizeThatFitsMaxSize.height
        } completion: { _ in
            multiselectToolbarContainer.removeFromSuperview()
            guard let tabController = self.tabBarController as? HomeTabBarController else { return }
            tabController.setTabBarHidden(false, animated: true, duration: 0.1)
        }
    }

    // MARK: Tab picker

    private enum FilterMode: Int {
        case all = 0
        case missed = 1
    }

    private lazy var tabPicker: UISegmentedControl = {
        let segmentedControl = UISegmentedControl(items: ["All", "Missed"]) // [CallsTab] TODO: Localize
        segmentedControl.selectedSegmentIndex = 0
        segmentedControl.addTarget(self, action: #selector(tabChanged), for: .valueChanged)
        return segmentedControl
    }()

    @objc
    private func tabChanged() {
        loadCallRecordsAnew(animated: true)
        updateMultiselectToolbarButtons()
    }

    private var currentFilterMode: FilterMode {
        FilterMode(rawValue: tabPicker.selectedSegmentIndex) ?? .all
    }

    // MARK: - Observers and Notifications

    private func attachSelfAsObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(groupCallInteractionWasUpdated),
            name: GroupCallInteractionUpdatedNotification.name,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(receivedCallRecordStoreNotification),
            name: CallRecordStoreNotification.name,
            object: nil
        )

        // No need to sync state since we're still setting up the view.
        deps.callService.addObserver(
            observer: self,
            syncStateImmediately: false
        )
    }

    /// When a group call interaction changes, we'll reload the row for the call
    /// it represents (if that row is loaded) so as to reflect the latest state
    /// for that group call.
    ///
    /// Recall that we track "is a group call ongoing" as a property on the
    /// interaction representing that group call, so we need this so we reload
    /// when the call ends.
    ///
    /// Note also that the ``didUpdateCall(from:to:)`` hook below is hit during
    /// the group-call-join process but before we have actually joined the call,
    /// due to the asynchronous nature of group calls. Consequently, we also
    /// need this hook to reload when we ourselves have joined the call, as us
    /// joining updates the "joined members" property also tracked on the group
    /// call interaction.
    @objc
    private func groupCallInteractionWasUpdated(_ notification: NSNotification) {
        guard let notification = GroupCallInteractionUpdatedNotification(notification) else {
            owsFail("Unexpectedly failed to instantiate group call interaction updated notification!")
        }

        let viewModelIdForGroupCall = CallViewModel.ID(
            callId: notification.callId,
            threadRowId: notification.groupThreadRowId
        )

        reloadRows(forIdentifiers: [viewModelIdForGroupCall])
    }

    @objc
    private func receivedCallRecordStoreNotification(_ notification: NSNotification) {
        guard let callRecordStoreNotification = CallRecordStoreNotification(notification) else {
            owsFail("Unexpected notification! \(type(of: notification))")
        }

        switch callRecordStoreNotification.updateType {
        case .inserted:
            newCallRecordWasInserted()
        case .deleted:
            owsFail("Not yet implemented!")
        case .statusUpdated:
            callRecordStatusWasUpdated(
                callId: callRecordStoreNotification.callId,
                threadRowId: callRecordStoreNotification.threadRowId
            )
        }
    }

    /// When a call record is inserted, we'll try loading newer records.
    ///
    /// The 99% case for a call record being inserted is that a new call was
    /// started – which is to say, the inserted call record is the most recent
    /// call. For this case, by loading newer calls we'll load that new call and
    /// present it at the top.
    ///
    /// It is possible that we'll have a call inserted into the middle of our
    /// existing calls, for example if we receive a delayed sync message about a
    /// call from a while ago that we somehow never learned about on this
    /// device. If that happens, we won't load and live-update with that call –
    /// instead, we'll see it the next time this view is reloaded.
    private func newCallRecordWasInserted() {
        /// Only attempt to load newer calls if the top row is visible. If not,
        /// we'll load newer calls when the user scrolls up anyway.
        let shouldLoadNewerCalls: Bool = {
            guard let visibleIndexPaths = tableView.indexPathsForVisibleRows else {
                return true
            }

            return visibleIndexPaths.contains(.indexPathForPrimarySection(row: 0))
        }()

        if shouldLoadNewerCalls {
            loadMoreCalls(direction: .newer, animated: true)
        }
    }

    /// When the status of a call record changes, we'll reload the row it
    /// represents (if that row is loaded) so as to reflect the latest state for
    /// that record.
    ///
    /// For example, imagine a ringing call that is declined on this device and
    /// accepted on another device. The other device will tell us it accepted
    /// via a sync message, and we should update this view to reflect the
    /// accepted call.
    private func callRecordStatusWasUpdated(
        callId: UInt64,
        threadRowId: Int64
    ) {
        let viewModelIdForUpdatedRecord = CallViewModel.ID(
            callId: callId,
            threadRowId: threadRowId
        )

        reloadRows(forIdentifiers: [viewModelIdForUpdatedRecord])
    }

    // MARK: CallServiceObserver

    /// When we learn that this device has joined or left a call, we'll reload
    /// any rows related to that call so that we show the latest state in this
    /// view.
    ///
    /// Recall that any 1:1 call we are not actively joined to has ended, and
    /// that that is not the case for group calls.
    func didUpdateCall(from oldValue: SignalCall?, to newValue: SignalCall?) {
        let callViewModelIdsToReload = [oldValue, newValue].compactMap { call -> CallViewModel.ID? in
            return call?.callViewModelId
        }

        reloadRows(forIdentifiers: callViewModelIdsToReload)
    }

    // MARK: - Call Record Loading

    /// Loads call records that we convert to ``CallViewModel``s. Configured on
    /// init with the current UI state of this view, e.g. filter mode and/or
    /// search term.
    private var callRecordLoader: CallRecordLoader!

    /// Recreates ``callRecordLoader`` with the current UI state, and kicks off
    /// an initial load.
    private func loadCallRecordsAnew(animated: Bool) {
        AssertIsOnMainThread()

        let onlyLoadMissedCalls: Bool = {
            switch currentFilterMode {
            case .all: return false
            case .missed: return true
            }
        }()

        // Throw away all our existing calls.
        calls = Calls(models: [])

        // Rebuild the loader.
        callRecordLoader = CallRecordLoader(
            callRecordQuerier: deps.callRecordQuerier,
            fullTextSearchFinder: deps.fullTextSearchFinder,
            configuration: CallRecordLoader.Configuration(
                onlyLoadMissedCalls: onlyLoadMissedCalls,
                searchTerm: searchTerm
            )
        )

        // Load the initial page of records.
        loadMoreCalls(direction: .older, animated: animated)
    }

    private enum LoadDirection {
        case older
        case newer
    }

    /// Load more calls and add them to the table.
    private func loadMoreCalls(
        direction loadDirection: LoadDirection,
        animated: Bool
    ) {
        deps.db.read { tx in
            let loaderLoadDirection: CallRecordLoader.LoadDirection = {
                switch loadDirection {
                case .older:
                    return .older(oldestCallTimestamp: calls.viewModels.last?.callBeganTimestamp)
                case .newer:
                    guard let newestCall = calls.viewModels.first else {
                        // A little weird, but if we have no calls these are
                        // equivalent anyway.
                        return .older(oldestCallTimestamp: nil)
                    }

                    return .newer(newestCallTimestamp: newestCall.callBeganTimestamp)
                }
            }()

            let newCallRecords: [CallRecord] = callRecordLoader.loadCallRecords(
                loadDirection: loaderLoadDirection,
                pageSize: Constants.pageSizeToLoad,
                tx: tx.asV2Read
            )

            let newViewModels: [CallViewModel] = newCallRecords.map { callRecord in
                return createCallViewModel(callRecord: callRecord, tx: tx)
            }

            let combinedViewModels: [CallViewModel] = {
                switch loadDirection {
                case .older: return calls.viewModels + newViewModels
                case .newer: return newViewModels + calls.viewModels
                }
            }()

            if combinedViewModels.count <= Constants.maxCallsToHoldAtOnce {
                calls = Calls(models: combinedViewModels)
            } else {
                let clampedModels: [CallViewModel] = {
                    let overage = combinedViewModels.count - Constants.maxCallsToHoldAtOnce
                    switch loadDirection {
                    case .older:
                        return Array(combinedViewModels.dropFirst(overage))
                    case .newer:
                        return Array(combinedViewModels.dropLast(overage))
                    }
                }()

                calls = Calls(models: clampedModels)
            }
        }

        updateSnapshot(animated: animated)
    }

    /// Converts a ``CallRecord`` to a ``CallViewModel``.
    ///
    /// - Note
    /// This method involves calls to external dependencies, as the view model
    /// state relies on state elsewhere in the app (such as any
    /// currently-ongoing calls).
    private func createCallViewModel(
        callRecord: CallRecord,
        tx: SDSAnyReadTransaction
    ) -> CallViewModel {
        guard let callThread = deps.threadStore.fetchThread(
            rowId: callRecord.threadRowId,
            tx: tx.asV2Read
        ) else {
            owsFail("Missing thread for call record! This should be impossible, per the DB schema.")
        }

        let callDirection: CallViewModel.Direction = {
            if callRecord.callStatus.isMissedCall {
                return .missed
            }

            switch callRecord.callDirection {
            case .incoming: return .incoming
            case .outgoing: return .outgoing
            }
        }()

        let callState: CallViewModel.State = {
            let currentCallId: UInt64? = deps.callService.currentCall?.callId

            switch callRecord.callStatus {
            case .individual:
                if callRecord.callId == currentCallId {
                    // We can have at most one 1:1 call active at a time, and if
                    // we have an active 1:1 call we must be in it. All other
                    // 1:1 calls must have ended.
                    return .participating
                }
            case .group:
                guard let groupCallInteraction: OWSGroupCallMessage = deps.interactionStore
                    .fetchAssociatedInteraction(
                        callRecord: callRecord, tx: tx.asV2Read
                    )
                else {
                    owsFail("Missing interaction for group call. This should be impossible per the DB schema!")
                }

                // We learn that a group call ended by peeking the group. During
                // that peek, we update the group call interaction. It's a
                // leetle wonky that we use the interaction to store that info,
                // but such is life.
                if !groupCallInteraction.hasEnded {
                    if callRecord.callId == currentCallId {
                        return .participating
                    }

                    return .active
                }
            }

            return .ended
        }()

        if let contactThread = callThread as? TSContactThread {
            let callType: CallViewModel.RecipientType.CallType = {
                switch callRecord.callType {
                case .audioCall:
                    return .audio
                case .groupCall:
                    owsFailDebug("Had group call type for 1:1 call!")
                    fallthrough
                case .videoCall:
                    return .video
                }
            }()

            return CallViewModel(
                backingCallRecord: callRecord,
                title: deps.contactsManager.displayName(
                    for: contactThread.contactAddress,
                    transaction: tx
                ),
                recipientType: .individual(type: callType, contactThread: contactThread),
                direction: callDirection,
                state: callState
            )
        } else if let groupThread = callThread as? TSGroupThread {
            return CallViewModel(
                backingCallRecord: callRecord,
                title: groupThread.groupModel.groupNameOrDefault,
                recipientType: .group(groupThread: groupThread),
                direction: callDirection,
                state: callState
            )
        } else {
            owsFail("Call thread was neither contact nor group! This should be impossible.")
        }
    }

    // MARK: - Table view

    fileprivate enum Section: Int, Hashable {
        case primary = 0
    }

    fileprivate struct CallViewModel: Hashable, Identifiable {
        enum Direction: Hashable {
            case outgoing
            case incoming
            case missed

            var label: String {
                switch self {
                case .outgoing:
                    return "Outgoing" // [CallsTab] TODO: Localize
                case .incoming:
                    return "Incoming" // [CallsTab] TODO: Localize
                case .missed:
                    return "Missed" // [CallsTab] TODO: Localize
                }
            }
        }

        enum State: Hashable {
            /// This call is active, but the user is not in it.
            case active
            /// The user is currently in this call.
            case participating
            /// The call is no longer active.
            case ended
        }

        enum RecipientType: Hashable {
            case individual(type: CallType, contactThread: TSContactThread)
            case group(groupThread: TSGroupThread)

            enum CallType: Hashable {
                case audio
                case video
            }
        }

        private let backingCallRecord: CallRecord

        let title: String
        let recipientType: RecipientType
        let direction: Direction
        let state: State

        var callId: UInt64 { backingCallRecord.callId }
        var threadRowId: Int64 { backingCallRecord.threadRowId }
        var callBeganTimestamp: UInt64 { backingCallRecord.callBeganTimestamp }
        var callBeganDate: Date { Date(millisecondsSince1970: callBeganTimestamp) }

        init(
            backingCallRecord: CallRecord,
            title: String,
            recipientType: RecipientType,
            direction: Direction,
            state: State
        ) {
            self.backingCallRecord = backingCallRecord
            self.title = title
            self.recipientType = recipientType
            self.direction = direction
            self.state = state
        }

        var callType: RecipientType.CallType {
            switch recipientType {
            case let .individual(callType, _):
                return callType
            case .group(_):
                return .video
            }
        }

        /// The `TSThread` for the call. If a `TSContactThread` or
        /// `TSGroupThread` is needed, switch on `recipientType`
        /// instead of typecasting this property.
        var thread: TSThread {
            switch recipientType {
            case let .individual(_, contactThread):
                return contactThread
            case let .group(groupThread):
                return groupThread
            }
        }

        var isMissed: Bool {
            switch direction {
            case .outgoing, .incoming:
                return false
            case .missed:
                return true
            }
        }

        // MARK: Hashable: Equatable

        static func == (lhs: CallViewModel, rhs: CallViewModel) -> Bool {
            return lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            id.hash(into: &hasher)
        }

        // MARK: Identifiable

        struct ID: Hashable {
            let callId: UInt64
            let threadRowId: Int64
        }

        var id: ID {
            ID(callId: callId, threadRowId: threadRowId)
        }
    }

    let tableView = UITableView(frame: .zero, style: .plain)

    /// - Important
    /// Don't use this directly – use ``searchTerm``.
    private var _searchTerm: String? {
        didSet {
            guard oldValue != searchTerm else {
                // If the term hasn't changed, don't do anything.
                return
            }

            loadCallRecordsAnew(animated: true)
        }
    }

    /// The user's current search term. Coalesces empty strings into `nil`.
    private var searchTerm: String? {
        get { _searchTerm?.nilIfEmpty }
        set { _searchTerm = newValue?.nilIfEmpty }
    }

    private struct Calls {
        private(set) var viewModels: [CallViewModel]
        private let modelIndicesByViewModelIds: [CallViewModel.ID: Int]

        init(models: [CallViewModel]) {
            var viewModels = [CallViewModel]()
            var modelIndicesByViewModelIds = [CallViewModel.ID: Int]()

            for (idx, viewModel) in models.enumerated() {
                viewModels.append(viewModel)
                modelIndicesByViewModelIds[viewModel.id] = idx
            }

            self.viewModels = viewModels
            self.modelIndicesByViewModelIds = modelIndicesByViewModelIds
        }

        subscript(id id: CallViewModel.ID) -> CallViewModel? {
            guard let index = modelIndicesByViewModelIds[id] else { return nil }
            return viewModels[index]
        }

        /// Recreates the view model for the given ID by calling the given
        /// block. If a given ID is not currently loaded, it is ignored.
        ///
        /// - Returns
        /// The IDs for the view models that were recreated. Note that this will
        /// not include any IDs that were ignored.
        mutating func recreateViewModels(
            ids: [CallViewModel.ID],
            recreateModelBlock: (CallViewModel.ID) -> CallViewModel?
        ) -> [CallViewModel.ID] {
            let indicesToReload: [(Int, CallViewModel)] = ids.compactMap { viewModelId in
                guard
                    let index = modelIndicesByViewModelIds[viewModelId],
                    let newViewModel = recreateModelBlock(viewModelId)
                else {
                    return nil
                }

                return (index, newViewModel)
            }

            for (index, newViewModel) in indicesToReload {
                viewModels[index] = newViewModel
            }

            return indicesToReload.map { $0.1.id }
        }
    }

    private var calls: Calls!

    private static var callCellReuseIdentifier = "callCell"

    private lazy var dataSource = UITableViewDiffableDataSource<Section, CallViewModel.ID>(tableView: tableView) { [weak self] tableView, indexPath, modelID -> UITableViewCell? in
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.callCellReuseIdentifier)

        guard let callCell = cell as? CallCell else {
            owsFail("Unexpected cell type")
        }

        callCell.delegate = self
        callCell.viewModel = self?.calls[id: modelID]

        return callCell
    }

    private func getSnapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.appendSections([.primary])
        snapshot.appendItems(calls.viewModels.map(\.id))
        return snapshot
    }

    private func updateSnapshot(animated: Bool) {
        dataSource.apply(getSnapshot(), animatingDifferences: animated)
        updateEmptyStateMessage()
    }

    /// Reload the rows for the given view model IDs that are currently loaded.
    private func reloadRows(forIdentifiers identifiersToReload: [CallViewModel.ID]) {
        // Recreate the view models, so when the data source reloads the rows
        // it'll reflect the new underlying state for that row.
        //
        // This step will also drop any IDs for models that are not currently
        // loaded, which should not be included in the snapshot.
        let identifiersToReload = deps.db.read { tx -> [CallViewModel.ID] in
            return calls.recreateViewModels(ids: identifiersToReload) { viewModelId -> CallViewModel? in
                switch deps.callRecordStore.fetch(
                    callId: viewModelId.callId,
                    threadRowId: viewModelId.threadRowId,
                    tx: tx.asV2Read
                ) {
                case .matchNotFound, .matchDeleted:
                    logger.warn("Call record missing while reloading!")
                    return nil
                case .matchFound(let freshCallRecord):
                    return createCallViewModel(callRecord: freshCallRecord, tx: tx)
                }
            }
        }

        var snapshot = getSnapshot()
        snapshot.reloadItems(identifiersToReload)
        dataSource.apply(snapshot)
    }

    private func reloadAllRows() {
        var snapshot = getSnapshot()
        snapshot.reloadSections([.primary])
        dataSource.apply(snapshot)
    }

    private func updateEmptyStateMessage() {
        switch (calls.viewModels.count, searchTerm) {
        case (0, .some(let searchTerm)) where !searchTerm.isEmpty:
            noSearchResultsView.text = "No results found for '\(searchTerm)'" // [CallsTab] TODO: Localize
            noSearchResultsView.layer.opacity = 1
            emptyStateMessageView.layer.opacity = 0
        case (0, _):
            emptyStateMessageView.attributedText = NSAttributedString.composed(of: {
                switch currentFilterMode {
                case .all:
                    return [
                        "No recent calls", // [CallsTab] TODO: Localize
                        "\n",
                        "Get started by calling a friend" // [CallsTab] TODO: Localize
                            .styled(with: .font(.dynamicTypeSubheadline)),
                    ]
                case .missed:
                    return [
                        "No missed calls" // [CallsTab] TODO: Localize
                    ]
                }
            }())
            .styled(
                with: .font(.dynamicTypeSubheadline.semibold())
            )
            noSearchResultsView.layer.opacity = 0
            emptyStateMessageView.layer.opacity = 1
        case (_, _):
            // Hide empty state message
            noSearchResultsView.layer.opacity = 0
            emptyStateMessageView.layer.opacity = 0
        }
    }
}

private extension IndexPath {
    static func indexPathForPrimarySection(row: Int) -> IndexPath {
        return IndexPath(
            row: row,
            section: CallsListViewController.Section.primary.rawValue
        )
    }
}

private extension SignalCall {
    var callId: UInt64? {
        switch mode {
        case .individual(let individualCall):
            return individualCall.callId
        case .group(let groupCall):
            return groupCall.peekInfo?.eraId.map { callIdFromEra($0) }
        }
    }

    var callViewModelId: CallsListViewController.CallViewModel.ID? {
        guard let callId else { return nil }
        return .init(callId: callId, threadRowId: threadRowId)
    }

    private var threadRowId: Int64 {
        guard let threadRowId = thread.sqliteRowId else {
            owsFail("How did we get a call whose thread does not exist in the DB?")
        }

        return threadRowId
    }
}

// MARK: UITableViewDelegate

extension CallsListViewController: UITableViewDelegate {

    private func viewModel(forRowAt indexPath: IndexPath) -> CallViewModel? {
        owsAssert(
            indexPath.section == Section.primary.rawValue,
            "Unexpected section for index path: \(indexPath.section)"
        )

        return calls.viewModels[safe: indexPath.row]
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if indexPath.row == 0 {
            DispatchQueue.main.async {
                // Try and load the next page if we're about to hit the top.
                DispatchQueue.main.async {
                    self.loadMoreCalls(direction: .newer, animated: false)
                }
            }
        }

        if indexPath.row == calls.viewModels.count - 1 {
            // Try and load the next page if we're about to hit the bottom.
            DispatchQueue.main.async {
                self.loadMoreCalls(direction: .older, animated: false)
            }
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateMultiselectToolbarButtons()
            return
        }

        tableView.deselectRow(at: indexPath, animated: true)

        guard let viewModel = viewModel(forRowAt: indexPath) else {
            return owsFailDebug("Missing view model")
        }
        callBack(from: viewModel)
    }

    func tableView(_ tableView: UITableView, didDeselectRowAt indexPath: IndexPath) {
        if tableView.isEditing {
            updateMultiselectToolbarButtons()
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        return self.longPressActions(forRowAt: indexPath)
            .map { actions in UIMenu.init(children: actions) }
            .map { menu in
                UIContextMenuConfiguration(identifier: indexPath as NSCopying, previewProvider: nil) { _ in menu }
            }
    }

    func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let viewModel = viewModel(forRowAt: indexPath) else {
            owsFailDebug("Missing call view model")
            return nil
        }

        let goToChatAction = makeContextualAction(
            style: .normal,
            color: .ows_accentBlue,
            image: "arrow-square-upright-fill",
            title: "Go to Chat" // [CallsTab] TODO: Localize
        ) { [weak self] in
            self?.goToChat(from: viewModel)
        }

        return .init(actions: [goToChatAction])
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let viewModel = viewModel(forRowAt: indexPath) else {
            owsFailDebug("Missing call view model")
            return nil
        }

        let deleteAction = makeContextualAction(
            style: .destructive,
            color: .ows_accentRed,
            image: "trash-fill",
            title: CommonStrings.deleteButton
        ) { [weak self] in
            self?.deleteCall(from: viewModel)
        }

        return .init(actions: [deleteAction])
    }

    private func makeContextualAction(
        style: UIContextualAction.Style,
        color: UIColor,
        image: String,
        title: String,
        action: @escaping () -> Void
    ) -> UIContextualAction {
        let action = UIContextualAction(
            style: style,
            title: nil
        ) { _, _, completion in
            action()
            completion(true)
        }
        action.backgroundColor = color
        action.image = UIImage(named: image)?.withTitle(
            title,
            font: .dynamicTypeFootnote.medium(),
            color: .ows_white,
            maxTitleWidth: 68,
            minimumScaleFactor: CGFloat(8) / CGFloat(13),
            spacing: 4
        )?.withRenderingMode(.alwaysTemplate)

        return action
    }

    private func longPressActions(forRowAt indexPath: IndexPath) -> [UIAction]? {
        guard let viewModel = viewModel(forRowAt: indexPath) else {
            owsFailDebug("Missing call view model")
            return nil
        }

        var actions = [UIAction]()

        switch viewModel.state {
        case .active:
            let joinCallTitle: String
            let joinCallIconName: String
            switch viewModel.callType {
            case .audio:
                joinCallTitle = "Join Audio Call" // [CallsTab] TODO: Localize
                joinCallIconName = Theme.iconName(.contextMenuVoiceCall)
            case .video:
                joinCallTitle = "Join Video Call" // [CallsTab] TODO: Localize
                joinCallIconName = Theme.iconName(.contextMenuVideoCall)
            }
            let joinCallAction = UIAction(
                title: joinCallTitle,
                image: UIImage(named: joinCallIconName),
                attributes: []
            ) { [weak self] _ in
                self?.joinCall(from: viewModel)
            }
            actions.append(joinCallAction)
        case .participating:
            let returnToCallIconName: String
            switch viewModel.callType {
            case .audio:
                returnToCallIconName = Theme.iconName(.contextMenuVoiceCall)
            case .video:
                returnToCallIconName = Theme.iconName(.contextMenuVideoCall)
            }
            let returnToCallAction = UIAction(
                title: "Return to Call", // [CallsTab] TODO: Localize
                image: UIImage(named: returnToCallIconName),
                attributes: []
            ) { [weak self] _ in
                self?.returnToCall(from: viewModel)
            }
            actions.append(returnToCallAction)
        case .ended:
            switch viewModel.recipientType {
            case .individual:
                let audioCallAction = UIAction(
                    title: "Audio Call", // [CallsTab] TODO: Localize
                    image: Theme.iconImage(.contextMenuVoiceCall),
                    attributes: []
                ) { [weak self] _ in
                    self?.startAudioCall(from: viewModel)
                }
                actions.append(audioCallAction)
            case .group:
                break
            }

            let videoCallAction = UIAction(
                title: "Video Call", // [CallsTab] TODO: Localize
                image: Theme.iconImage(.contextMenuVideoCall),
                attributes: []
            ) { [weak self] _ in
                self?.startVideoCall(from: viewModel)
            }
            actions.append(videoCallAction)
        }

        let goToChatAction = UIAction(
            title: "Go to Chat", // [CallsTab] TODO: Localize
            image: Theme.iconImage(.contextMenuOpenInChat),
            attributes: []
        ) { [weak self] _ in
            self?.goToChat(from: viewModel)
        }
        actions.append(goToChatAction)

        let infoAction = UIAction(
            title: "Info", // [CallsTab] TODO: Localize
            image: Theme.iconImage(.contextMenuInfo),
            attributes: []
        ) { [weak self] _ in
            self?.showCallInfo(from: viewModel)
        }
        actions.append(infoAction)

        let selectAction = UIAction(
            title: "Select", // [CallsTab] TODO: Localize
            image: Theme.iconImage(.contextMenuSelect),
            attributes: []
        ) { [weak self] _ in
            self?.selectCall(forRowAt: indexPath)
        }
        actions.append(selectAction)

        switch viewModel.state {
        case .active, .ended:
            let deleteAction = UIAction(
                title: "Delete", // [CallsTab] TODO: Localize
                image: Theme.iconImage(.contextMenuDelete),
                attributes: .destructive
            ) { [weak self] _ in
                self?.deleteCall(from: viewModel)
            }
            actions.append(deleteAction)
        case .participating:
            break
        }

        return actions
    }
}

// MARK: - Actions

extension CallsListViewController: CallCellDelegate {

    private func callBack(from viewModel: CallViewModel) {
        switch viewModel.callType {
        case .audio:
            startAudioCall(from: viewModel)
        case .video:
            startVideoCall(from: viewModel)
        }
    }

    private func startAudioCall(from viewModel: CallViewModel) {
        // [CallsTab] TODO: See ConversationViewController.startIndividualCall(withVideo:)
        switch viewModel.recipientType {
        case let .individual(_, contactThread):
            callService.initiateCall(thread: contactThread, isVideo: false)
        case .group:
            owsFail("Shouldn't be able to start audio call from group")
        }
    }

    private func startVideoCall(from viewModel: CallViewModel) {
        // [CallsTab] TODO: Check if the conversation is blocked or there's a message request.
        // See ConversationViewController.startIndividualCall(withVideo:)
        // and  ConversationViewController.showGroupLobbyOrActiveCall()
        switch viewModel.recipientType {
        case let .individual(_, contactThread):
            callService.initiateCall(thread: contactThread, isVideo: true)
        case let .group(groupThread):
            GroupCallViewController.presentLobby(thread: groupThread)
        }
    }

    private func goToChat(from viewModel: CallViewModel) {
        SignalApp.shared.presentConversationForThread(viewModel.thread, action: .compose, animated: false)
    }

    private func deleteCall(from viewModel: CallViewModel) {
        Logger.debug("Delete call")
    }

    private func selectCall(forRowAt indexPath: IndexPath) {
        startMultiselect()
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
    }

    // MARK: CallCellDelegate

    fileprivate func joinCall(from viewModel: CallViewModel) {
        Logger.debug("Join call")
    }

    fileprivate func returnToCall(from viewModel: CallViewModel) {
        Logger.debug("Return to call")
    }

    fileprivate func showCallInfo(from viewModel: CallViewModel) {
        Logger.debug("Show call info")
    }
}

// MARK: UISearchResultsUpdating

extension CallsListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        self.searchTerm = searchController.searchBar.text
    }
}

// MARK: - Call cell

extension CallsListViewController {
    fileprivate class CallCell: UITableViewCell {

        private static var verticalMargin: CGFloat = 11
        private static var horizontalMargin: CGFloat = 20
        private static var joinButtonMargin: CGFloat = 18
        // [CallsTab] TODO: Dynamic type?
        private static var subtitleIconSize: CGFloat = 16

        weak var delegate: CallCellDelegate?

        var viewModel: CallViewModel? {
            didSet {
                updateContents()
            }
        }

        // MARK: Subviews

        private lazy var avatarView = ConversationAvatarView(
            sizeClass: .thirtySix,
            localUserDisplayMode: .asUser
        )

        private lazy var titleLabel: UILabel = {
            let label = UILabel()
            label.font = .dynamicTypeHeadline
            return label
        }()

        private lazy var subtitleIcon: UIImageView = UIImageView()
        private lazy var subtitleLabel: UILabel = {
            let label = UILabel()
            label.font = .dynamicTypeBody2
            return label
        }()

        private lazy var timestampLabel: UILabel = {
            let label = UILabel()
            label.font = .dynamicTypeBody2
            return label
        }()

        private lazy var detailsButton: OWSButton = {
            let button = OWSButton { [weak self] in
                self?.detailsTapped()
            }
            // The info icon is the button's own image and should be `horizontalMargin` from the edge
            button.contentEdgeInsets.trailing = Self.horizontalMargin
            button.contentEdgeInsets.leading = 8
            // The join button is a separate subview and should be `joinButtonMargin` from the edge
            button.layoutMargins.trailing = Self.joinButtonMargin
            return button
        }()

        private var joinPill: UIView?

        private func makeJoinPill() -> UIView? {
            guard let viewModel else { return nil }

            let icon: UIImage?
            switch viewModel.callType {
            case .audio:
                icon = Theme.iconImage(.phoneFill16)
            case .video:
                icon = Theme.iconImage(.videoFill16)
            }

            let text: String
            switch viewModel.state {
            case .active:
                text = "Join" // [CallsTab] TODO: Localize
            case .participating:
                text = "Return" // [CallsTab] TODO: Localize
            case .ended:
                return nil
            }

            let iconView = UIImageView(image: icon)
            iconView.tintColor = .ows_white

            let label = UILabel()
            label.text = text
            label.font = .dynamicTypeBody2Clamped.bold()
            label.textColor = .ows_white

            let stackView = UIStackView(arrangedSubviews: [iconView, label])
            stackView.addPillBackgroundView(backgroundColor: .ows_accentGreen)
            stackView.layoutMargins = .init(hMargin: 12, vMargin: 4)
            stackView.isLayoutMarginsRelativeArrangement = true
            stackView.isUserInteractionEnabled = false
            stackView.spacing = 4
            return stackView
        }

        // MARK: Init

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)

            let subtitleHStack = UIStackView(arrangedSubviews: [subtitleIcon, subtitleLabel])
            subtitleHStack.axis = .horizontal
            subtitleHStack.spacing = 6
            subtitleIcon.autoSetDimensions(to: .square(Self.subtitleIconSize))

            let bodyVStack = UIStackView(arrangedSubviews: [
                titleLabel,
                subtitleHStack,
            ])
            bodyVStack.axis = .vertical
            bodyVStack.spacing = 2

            let leadingHStack = UIStackView(arrangedSubviews: [
                avatarView,
                bodyVStack,
            ])
            leadingHStack.axis = .horizontal
            leadingHStack.spacing = 12

            let trailingHStack = UIStackView(arrangedSubviews: [
                timestampLabel,
                detailsButton,
            ])
            trailingHStack.axis = .horizontal
            trailingHStack.spacing = 0

            let outerHStack = UIStackView(arrangedSubviews: [
                leadingHStack,
                UIView(),
                trailingHStack,
            ])
            outerHStack.axis = .horizontal
            outerHStack.spacing = 4

            // The details button should take up the entire trailing space,
            // top to bottom, so the content should have zero margins.
            contentView.preservesSuperviewLayoutMargins = false
            contentView.layoutMargins = .zero

            leadingHStack.preservesSuperviewLayoutMargins = false
            leadingHStack.isLayoutMarginsRelativeArrangement = true
            leadingHStack.layoutMargins = .init(
                top: Self.verticalMargin,
                leading: Self.horizontalMargin,
                bottom: Self.verticalMargin,
                trailing: 0
            )

            contentView.addSubview(outerHStack)
            outerHStack.autoPinEdgesToSuperviewMargins()

            tintColor = .ows_accentBlue
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        // MARK: Updates

        private func updateContents() {
            applyTheme()

            guard let viewModel else {
                return owsFailDebug("Missing view model")
            }

            avatarView.updateWithSneakyTransactionIfNecessary { configuration in
                configuration.dataSource = .thread(viewModel.thread)
            }

            self.titleLabel.text = viewModel.title
            self.subtitleLabel.text = viewModel.direction.label

            switch viewModel.direction {
            case .incoming, .outgoing:
                titleLabel.textColor = Theme.primaryTextColor
            case .missed:
                titleLabel.textColor = .ows_accentRed
            }

            switch viewModel.callType {
            case .audio:
                subtitleIcon.image = Theme.iconImage(.phone16)
            case .video:
                subtitleIcon.image = Theme.iconImage(.video16)
            }

            self.joinPill?.removeFromSuperview()

            switch viewModel.state {
            case .active, .participating:
                // Join button
                detailsButton.setImage(imageName: nil)
                detailsButton.tintColor = .ows_white

                if let joinPill = makeJoinPill() {
                    self.joinPill = joinPill
                    detailsButton.addSubview(joinPill)
                    joinPill.autoVCenterInSuperview()
                    joinPill.autoPinWidthToSuperviewMargins()
                }

                timestampLabel.text = nil
            case .ended:
                // Info button
                detailsButton.setImage(imageName: "info")
                detailsButton.tintColor = Theme.primaryIconColor

                timestampLabel.text = DateUtil.formatDateShort(viewModel.callBeganDate)
                // [CallsTab] TODO: Automatic updates
                // See ChatListCell.nextUpdateTimestamp
            }
        }

        private func applyTheme() {
            backgroundColor = Theme.backgroundColor
            selectedBackgroundView?.backgroundColor = Theme.tableCell2SelectedBackgroundColor
            multipleSelectionBackgroundView?.backgroundColor = Theme.tableCell2MultiSelectedBackgroundColor

            titleLabel.textColor = Theme.primaryTextColor
            subtitleIcon.tintColor = Theme.secondaryTextAndIconColor
            subtitleLabel.textColor = Theme.secondaryTextAndIconColor
            timestampLabel.textColor = Theme.secondaryTextAndIconColor
        }

        // MARK: Actions

        private func detailsTapped() {
            guard let viewModel else {
                return owsFailDebug("Missing view model")
            }

            guard let delegate else {
                return owsFailDebug("Missing delegate")
            }

            switch viewModel.state {
            case .active:
                delegate.joinCall(from: viewModel)
            case .participating:
                delegate.returnToCall(from: viewModel)
            case .ended:
                delegate.showCallInfo(from: viewModel)
            }
        }
    }
}
