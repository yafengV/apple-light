import SwiftUI

struct EnvironmentActionsMenu: View {
  let actions: [EnvironmentAction]
  let run: (EnvironmentAction) -> Void

  var body: some View {
    Menu {
      ForEach(actions.filter(\.isRunnableOnMac)) { action in
        Button {
          run(action)
        } label: {
          Label(action.title, systemImage: action.systemImage)
        }
      }
    } label: {
      Label("操作", systemImage: "play.square")
    }
    .help("运行项目快捷操作")
  }
}
