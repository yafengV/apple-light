import XCTest
@testable import ShipiOS

@MainActor final class EnvironmentReadConcurrencyTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let project: URL
    let executable: URL
    let gate: URL
    let reached: URL
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath().standardizedFileURL
    let project = root.appendingPathComponent("Project"), executable = root.appendingPathComponent("agent")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let script = #"""
    #!/usr/bin/python3
    import json, pathlib, sys, threading, time
    project = pathlib.Path(sys.argv[sys.argv.index('--project') + 1])
    root = project.parent
    lock = threading.Lock()
    counts = {}
    def respond(request):
        method = request['method']
        name = request.get('params', {}).get('fileName', '')
        if project.name == 'Other' and method == 'initialize' and (root / 'scope-gate').exists():
            (root / 'scope-reached').touch()
            while (root / 'scope-gate').exists(): time.sleep(0.01)
        if project.name == 'Other' and method == 'environment.save' and (root / 'save-gate').exists():
            (root / 'save-reached').touch()
            while (root / 'save-gate').exists(): time.sleep(0.01)
        held = False
        error = False
        with lock:
            key = (method, name)
            counts[key] = counts.get(key, 0) + 1
            count = counts[key]
            if (root / 'gate').exists() and not (root / 'claimed').exists():
                spec = json.loads((root / 'gate').read_text())
                if spec['method'] == method and (not spec.get('file') or spec['file'] == name):
                    held = True
                    error = spec.get('error', False)
                    (root / 'claimed').touch()
                    (root / 'reached').touch()
        label = name + ':' + str(count)
        values = {'initialize': {'protocolVersion': 1}, 'config.get': {}, 'run.list': [],
            'project.inspect': {'root': str(project), 'containers': [], 'swiftPackages': [], 'diagnostics': [], 'scanTruncated': False},
            'environment.list': [{'id': f, 'fileName': f, 'name': f, 'error': None, 'inherited': False, 'sourceFolder': str(project)} for f in ['environment.toml', 'environment-2.toml']],
            'environment.load': {'exists': True, 'revision': label, 'error': None,
                'config': {'name': label, 'setup': {'script': 'echo ' + label}, 'actions': []}},
            'environment.save': {'exists': True, 'revision': 'saved:' + str(count)}}
        if method == 'environment.save':
            with lock:
                (root / 'submitted.json').write_text(json.dumps(request['params']))
        response = {'jsonrpc': '2.0', 'id': request['id'], 'result': values.get(method, {})}
        if error:
            response.pop('result')
            response['error'] = {'code': -32000, 'message': 'obsolete read failure'}
        if held:
            while (root / 'gate').exists(): time.sleep(0.01)
        with lock:
            print(json.dumps(response), flush=True)
    for line in sys.stdin:
        threading.Thread(target=respond, args=(json.loads(line),), daemon=True).start()
    if project.name == 'Project' and (root / 'stop-gate').exists():
        (root / 'stop-reached').touch()
        while (root / 'stop-gate').exists(): time.sleep(0.01)
    """#
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return .init(root: root, project: project, executable: executable,
      gate: root.appendingPathComponent("gate"), reached: root.appendingPathComponent("reached"))
  }

  private func hold(_ fixture: Fixture, method: String, file: String = "", error: Bool = false) throws {
    try JSONSerialization.data(withJSONObject: ["method": method, "file": file, "error": error]).write(to: fixture.gate)
  }
  private func reached(_ fixture: Fixture) async throws {
    for _ in 0..<120 where !FileManager.default.fileExists(atPath: fixture.reached.path) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.reached.path))
  }
  private func workspace(_ fixture: Fixture) async -> WorkspaceStore {
    let store = WorkspaceStore(dataRoot: fixture.root.appendingPathComponent("Data"), agentExecutable: fixture.executable)
    await store.open(fixture.project)
    XCTAssertTrue(store.connected, store.error ?? "")
    addTeardownBlock { @MainActor in
      try? FileManager.default.removeItem(at: fixture.gate)
      try? FileManager.default.removeItem(at: fixture.root.appendingPathComponent("scope-gate"))
      await store.shutdown()
    }
    return store
  }
  private func editor(_ fixture: Fixture) async -> EnvironmentSettingsSession {
    let editor = EnvironmentSettingsSession()
    await editor.open(fixture.project.path, title: "Project", executable: fixture.executable)
    XCTAssertTrue(editor.connected, editor.status)
    addTeardownBlock { @MainActor in
      try? FileManager.default.removeItem(at: fixture.gate)
      try? FileManager.default.removeItem(at: fixture.root.appendingPathComponent("stop-gate"))
      try? FileManager.default.removeItem(at: fixture.root.appendingPathComponent("save-gate"))
      await editor.close()
    }
    return editor
  }

  func testWorkspaceABARejectsOlderSuccessAndFailure() async throws {
    for error in [false, true] {
      let f = try fixture(), store = await workspace(f)
      try hold(f, method: "environment.load", file: "environment.toml", error: error)
      let old = Task { await store.loadSharedEnvironment() }; try await reached(f)
      await store.selectSharedEnvironment("environment-2.toml")
      await store.selectSharedEnvironment("environment.toml")
      let form = store.currentEnvironmentFormState, revision = store.environmentRevision, status = store.environmentStatus
      XCTAssertEqual(revision, "environment.toml:3")
      try FileManager.default.removeItem(at: f.gate); await old.value
      XCTAssertEqual(store.currentEnvironmentFormState, form); XCTAssertEqual(store.environmentRevision, revision)
      XCTAssertEqual(store.environmentStatus, status); XCTAssertTrue(store.environmentExists)
      XCTAssertEqual(store.environmentLoadedState, form)
    }
  }

  func testEditorABARejectsOlderSuccessAndFailure() async throws {
    for error in [false, true] {
      let f = try fixture(), editor = await editor(f)
      try hold(f, method: "environment.load", file: "environment.toml", error: error)
      let old = Task { await editor.load() }; try await reached(f)
      await editor.select("environment-2.toml"); await editor.select("environment.toml")
      let form = editor.formState, revision = editor.revision, status = editor.status
      XCTAssertEqual(revision, "environment.toml:3")
      try FileManager.default.removeItem(at: f.gate); await old.value
      XCTAssertEqual(editor.formState, form); XCTAssertEqual(editor.revision, revision)
      XCTAssertEqual(editor.status, status); XCTAssertTrue(editor.exists); XCTAssertFalse(editor.readError)
      XCTAssertEqual(editor.loadedState, form)
    }
  }

  func testWorkspaceOldDirectoryRefreshCannotReloadNewSelectionOrCreation() async throws {
    for create in [false, true] {
      let f = try fixture(), store = await workspace(f)
      try hold(f, method: "environment.list")
      let old = Task { await store.refreshSharedEnvironments() }; try await reached(f)
      if create { store.createSharedEnvironment() }
      else { await store.selectSharedEnvironment("environment-2.toml") }
      store.environmentName = "keep new draft"
      let file = store.environmentFileName, form = store.currentEnvironmentFormState
      let revision = store.environmentRevision, exists = store.environmentExists, status = store.environmentStatus
      try FileManager.default.removeItem(at: f.gate); await old.value
      XCTAssertEqual(store.environmentFileName, file); XCTAssertEqual(store.currentEnvironmentFormState, form)
      XCTAssertEqual(store.environmentRevision, revision); XCTAssertEqual(store.environmentExists, exists)
      XCTAssertEqual(store.environmentStatus, status); XCTAssertTrue(store.environmentHasUnsavedChanges)
    }
  }

  func testEditorOldDirectoryRefreshCannotReloadNewSelectionOrCreation() async throws {
    for create in [false, true] {
      let f = try fixture(), editor = await editor(f)
      try hold(f, method: "environment.list")
      let old = Task { await editor.refresh() }; try await reached(f)
      if create { editor.create() }
      else { await editor.select("environment-2.toml") }
      editor.name = "keep new draft"
      let file = editor.fileName, form = editor.formState
      let revision = editor.revision, exists = editor.exists, status = editor.status
      try FileManager.default.removeItem(at: f.gate); await old.value
      XCTAssertEqual(editor.fileName, file); XCTAssertEqual(editor.formState, form)
      XCTAssertEqual(editor.revision, revision); XCTAssertEqual(editor.exists, exists)
      XCTAssertEqual(editor.status, status); XCTAssertTrue(editor.hasUnsavedChanges)
    }
  }

  func testCancelledWorkspaceReadsDoNotApplySuccessOrFailure() async throws {
    for error in [false, true] {
      let f = try fixture(), store = await workspace(f)
      let initial = store.currentEnvironmentFormState, initialRevision = store.environmentRevision
      let cancelled = Task { await store.loadSharedEnvironment(); await store.refreshSharedEnvironments() }
      cancelled.cancel(); await cancelled.value
      XCTAssertEqual(store.currentEnvironmentFormState, initial); XCTAssertEqual(store.environmentRevision, initialRevision)
      try hold(f, method: "environment.load", file: "environment.toml", error: error)
      let form = store.currentEnvironmentFormState, status = store.environmentStatus, revision = store.environmentRevision
      let exists = store.environmentExists
      let pending = Task { await store.loadSharedEnvironment() }; try await reached(f)
      pending.cancel(); try FileManager.default.removeItem(at: f.gate); await pending.value
      XCTAssertEqual(store.currentEnvironmentFormState, form); XCTAssertEqual(store.environmentStatus, status)
      XCTAssertEqual(store.environmentRevision, revision); XCTAssertEqual(store.environmentExists, exists)
    }
  }

  func testCancelledEditorReadsDoNotApplySuccessOrFailure() async throws {
    for error in [false, true] {
      let f = try fixture(), editor = await editor(f)
      let initial = editor.formState, initialRevision = editor.revision
      let cancelled = Task { await editor.load(); await editor.refresh() }
      cancelled.cancel(); await cancelled.value
      XCTAssertEqual(editor.formState, initial); XCTAssertEqual(editor.revision, initialRevision)
      try hold(f, method: "environment.load", file: "environment.toml", error: error)
      let form = editor.formState, status = editor.status, revision = editor.revision
      let exists = editor.exists
      let pending = Task { await editor.load() }; try await reached(f)
      pending.cancel(); try FileManager.default.removeItem(at: f.gate); await pending.value
      XCTAssertEqual(editor.formState, form); XCTAssertEqual(editor.status, status)
      XCTAssertEqual(editor.revision, revision); XCTAssertEqual(editor.exists, exists); XCTAssertFalse(editor.readError)
    }
  }

  func testStoppedEnvironmentReadCannotClearSourceWhileNextProjectPrepares() async throws {
    let f = try fixture(), store = await workspace(f)
    let other = f.root.appendingPathComponent("Other"), scopeGate = f.root.appendingPathComponent("scope-gate")
    let scopeReached = f.root.appendingPathComponent("scope-reached")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try hold(f, method: "environment.load", file: "environment.toml")
    let pending = Task { await store.loadSharedEnvironment() }; try await reached(f)
    let form = store.currentEnvironmentFormState, status = store.environmentStatus
    try Data().write(to: scopeGate)
    let navigation = Task { await store.open(other, loadsDetails: false) }
    for _ in 0..<120 where !FileManager.default.fileExists(atPath: scopeReached.path) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: scopeReached.path))
    await pending.value
    XCTAssertEqual(store.project?.path, f.project.path); XCTAssertTrue(store.preparingProjectScope)
    XCTAssertEqual(store.currentEnvironmentFormState, form); XCTAssertEqual(store.environmentStatus, status)
    try FileManager.default.removeItem(at: f.gate)
    try FileManager.default.removeItem(at: scopeGate); await navigation.value
    XCTAssertEqual(store.project?.path, other.path); XCTAssertTrue(store.connected)
    XCTAssertEqual(store.environmentName, "environment.toml:1")
  }

  func testWorkspaceSaveOnlyMarksSubmittedFormAsSaved() async throws {
    let f = try fixture(), store = await workspace(f)
    store.environmentName = "submitted"; store.worktreeCleanupScript = "echo submitted"
    let submitted = store.currentEnvironmentFormState
    try hold(f, method: "environment.save", file: "environment.toml")
    let save = Task { await store.saveSharedEnvironment() }; try await reached(f)
    store.environmentName = "new draft"; store.worktreeCleanupScript = "echo new draft"
    try FileManager.default.removeItem(at: f.gate)
    let saved = await save.value
    XCTAssertTrue(saved); XCTAssertEqual(store.environmentLoadedState, submitted)
    XCTAssertTrue(store.environmentHasUnsavedChanges); XCTAssertEqual(store.environmentName, "new draft")
    XCTAssertEqual(store.worktreeCleanupScript, "echo new draft"); XCTAssertEqual(store.environmentRevision, "saved:1")
    XCTAssertFalse(store.environmentSaving)
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: f.root.appendingPathComponent("submitted.json")))
    XCTAssertEqual(payload["config"]["name"].text, "submitted")
    XCTAssertEqual(payload["config"]["cleanup"]["script"].text, "echo submitted")
  }

  func testEditorSaveOnlyMarksSubmittedFormAsSaved() async throws {
    let f = try fixture(), editor = await editor(f)
    editor.name = "submitted"; editor.cleanupScript = "echo submitted"
    let submitted = editor.formState
    try hold(f, method: "environment.save", file: "environment.toml")
    let save = Task { await editor.save() }; try await reached(f)
    editor.name = "new draft"; editor.cleanupScript = "echo new draft"
    try FileManager.default.removeItem(at: f.gate)
    let saved = await save.value
    XCTAssertTrue(saved); XCTAssertEqual(editor.loadedState, submitted); XCTAssertTrue(editor.hasUnsavedChanges)
    XCTAssertTrue(editor.canSave); XCTAssertEqual(editor.name, "new draft")
    XCTAssertEqual(editor.cleanupScript, "echo new draft"); XCTAssertEqual(editor.revision, "saved:1")
    XCTAssertFalse(editor.saving)
  }

  func testWorkspaceOldSaveAndCatalogReplyCannotApplyAfterABASelection() async throws {
    for method in ["environment.save", "environment.list"] {
      for error in [false, true] {
        let f = try fixture(), store = await workspace(f)
        store.environmentName = "submitted"
        try hold(f, method: method, error: error)
        let save = Task { await store.saveSharedEnvironment() }; try await reached(f)
        await store.selectSharedEnvironment("environment-2.toml"); await store.selectSharedEnvironment("environment.toml")
        let form = store.currentEnvironmentFormState, revision = store.environmentRevision, status = store.environmentStatus
        try FileManager.default.removeItem(at: f.gate)
        let saved = await save.value
        XCTAssertFalse(saved, method); XCTAssertEqual(store.currentEnvironmentFormState, form)
        XCTAssertEqual(store.environmentRevision, revision); XCTAssertEqual(store.environmentStatus, status)
        XCTAssertEqual(store.environmentLoadedState, form); XCTAssertFalse(store.environmentSaving)
      }
    }
  }

  func testEditorOldSaveAndCatalogReplyCannotApplyAfterABASelection() async throws {
    for method in ["environment.save", "environment.list"] {
      for error in [false, true] {
        let f = try fixture(), editor = await editor(f)
        editor.name = "submitted"
        try hold(f, method: method, error: error)
        let save = Task { await editor.save() }; try await reached(f)
        await editor.select("environment-2.toml"); await editor.select("environment.toml")
        let form = editor.formState, revision = editor.revision, status = editor.status
        try FileManager.default.removeItem(at: f.gate)
        let saved = await save.value
        XCTAssertFalse(saved, method); XCTAssertEqual(editor.formState, form); XCTAssertEqual(editor.revision, revision)
        XCTAssertEqual(editor.status, status); XCTAssertEqual(editor.loadedState, form)
        XCTAssertFalse(editor.readError); XCTAssertFalse(editor.saveConflict); XCTAssertFalse(editor.saving)
      }
    }
  }

  func testSavingInvalidatesOlderWorkspaceRead() async throws {
    let f = try fixture(), store = await workspace(f)
    try hold(f, method: "environment.load", file: "environment.toml")
    let read = Task { await store.loadSharedEnvironment() }; try await reached(f)
    store.environmentName = "submitted"
    let saved = await store.saveSharedEnvironment(); XCTAssertTrue(saved)
    let form = store.currentEnvironmentFormState, revision = store.environmentRevision, status = store.environmentStatus
    try FileManager.default.removeItem(at: f.gate); await read.value
    XCTAssertEqual(store.currentEnvironmentFormState, form); XCTAssertEqual(store.environmentRevision, revision)
    XCTAssertEqual(store.environmentStatus, status); XCTAssertFalse(store.environmentHasUnsavedChanges)
  }

  func testSavingInvalidatesOlderEditorRead() async throws {
    let f = try fixture(), editor = await editor(f)
    try hold(f, method: "environment.load", file: "environment.toml")
    let read = Task { await editor.load() }; try await reached(f)
    editor.name = "submitted"
    let saved = await editor.save(); XCTAssertTrue(saved)
    let form = editor.formState, revision = editor.revision, status = editor.status
    try FileManager.default.removeItem(at: f.gate); await read.value
    XCTAssertEqual(editor.formState, form); XCTAssertEqual(editor.revision, revision)
    XCTAssertEqual(editor.status, status); XCTAssertFalse(editor.hasUnsavedChanges)
  }

  func testClosingOldEditorCannotClearReopenedProject() async throws {
    let f = try fixture(), editor = await editor(f)
    let other = f.root.appendingPathComponent("Other"), stopGate = f.root.appendingPathComponent("stop-gate")
    let stopReached = f.root.appendingPathComponent("stop-reached")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try Data().write(to: stopGate)
    let close = Task { await editor.close() }
    for _ in 0..<120 where !FileManager.default.fileExists(atPath: stopReached.path) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: stopReached.path))
    await editor.open(other.path, title: "Other", executable: f.executable)
    let form = editor.formState, files = editor.files.map(\.id)
    try FileManager.default.removeItem(at: stopGate); await close.value
    XCTAssertEqual(editor.projectPath, other.path); XCTAssertEqual(editor.formState, form)
    XCTAssertEqual(editor.files.map(\.id), files); XCTAssertFalse(files.isEmpty)
    XCTAssertTrue(editor.connected); XCTAssertFalse(editor.loading)
  }

  func testOldSaveCleanupCannotClearNewEditorSavingFlag() async throws {
    let f = try fixture(), editor = await editor(f)
    editor.name = "old submitted"
    try hold(f, method: "environment.save", file: "environment.toml")
    let oldSave = Task { await editor.save() }; try await reached(f)
    let stopGate = f.root.appendingPathComponent("stop-gate"), stopReached = f.root.appendingPathComponent("stop-reached")
    try Data().write(to: stopGate)
    let close = Task { await editor.close() }
    for _ in 0..<120 where !FileManager.default.fileExists(atPath: stopReached.path) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: stopReached.path))
    let other = f.root.appendingPathComponent("Other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    await editor.open(other.path, title: "Other", executable: f.executable)
    editor.name = "new submitted"
    let saveGate = f.root.appendingPathComponent("save-gate"), saveReached = f.root.appendingPathComponent("save-reached")
    try Data().write(to: saveGate)
    let newSave = Task { await editor.save() }
    for _ in 0..<120 where !FileManager.default.fileExists(atPath: saveReached.path) {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: saveReached.path)); XCTAssertTrue(editor.saving)
    try FileManager.default.removeItem(at: stopGate)
    let oldSaved = await oldSave.value; await close.value
    XCTAssertFalse(oldSaved); XCTAssertTrue(editor.saving); XCTAssertEqual(editor.projectPath, other.path)
    try FileManager.default.removeItem(at: f.gate)
    try FileManager.default.removeItem(at: saveGate)
    let newSaved = await newSave.value
    XCTAssertTrue(newSaved); XCTAssertFalse(editor.saving); XCTAssertEqual(editor.name, "new submitted")
    XCTAssertTrue(editor.connected); XCTAssertFalse(editor.hasUnsavedChanges)
  }
}
