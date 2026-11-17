// Linko workspace (Plan 4 Task 1): one workspace holding the single root
// project; module projects join the workspace list as their tasks add them.
import ProjectDescription

let workspace = Workspace(
    name: "Linko",
    projects: [
        ".",
    ]
)
