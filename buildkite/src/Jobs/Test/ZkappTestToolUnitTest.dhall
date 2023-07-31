let Prelude = ../../External/Prelude.dhall

let Cmd = ../../Lib/Cmds.dhall
let S = ../../Lib/SelectFiles.dhall
let D = S.PathPattern

let Pipeline = ../../Pipeline/Dsl.dhall
let JobSpec = ../../Pipeline/JobSpec.dhall

let Command = ../../Command/Base.dhall
let RunInToolchain = ../../Command/RunInToolchain.dhall
let Docker = ../../Command/Docker/Type.dhall
let Size = ../../Command/Size.dhall

let buildTestCmd : Text -> Text -> Size -> Command.Type = \(profile : Text) -> \(path : Text) -> \(cmd_target : Size) ->
  Command.build
    Command.Config::{
      commands = RunInToolchain.runInToolchain ([] : List Text) "buildkite/scripts/unit-test.sh ${profile} ${path}",
      label = "Zkapps test transaction tool unit tests",
      key = "zkapp-tool-unit-test-${profile}",
      target = cmd_target,
      docker = None Docker.Type,
      artifact_paths = [ S.contains "core_dumps/*" ]
    }

in

Pipeline.build
  Pipeline.Config::{
    spec = 
      let unitDirtyWhen = [
        S.strictlyStart (S.contains "src/lib"),
        S.strictlyStart (S.contains "src/app/zkapp_test_transaction"),
        S.exactly "buildkite/src/Jobs/Test/ZkappTestToolUnitTest" "dhall",
        S.exactly "buildkite/scripts/unit-test" "sh"
      ]

      in

      JobSpec::{
        dirtyWhen = unitDirtyWhen,
        path = "Test",
        name = "ZkappTestToolUnitTest"
      },
    steps = [
      buildTestCmd "dev" "src/app/zkapp_test_transaction" Size.Small
    ]
  }
