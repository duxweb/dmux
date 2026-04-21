# Dmux Overview

## Main code paths

- App entry: `Sources/DmuxWorkspace/DmuxWorkspaceApp.swift`
- Main coordinator: `Sources/DmuxWorkspace/App/AppModel.swift`
- Main shell: `Sources/DmuxWorkspace/UI/RootView.swift`
- Workspace composition: `Sources/DmuxWorkspace/UI/Workspace/WorkspaceView.swift`
- Sidebar: `Sources/DmuxWorkspace/UI/Sidebar/SidebarView.swift`

## Main stores

- `AppModel`
- `AIStatsStore`
- `AISessionStore`
- `GitStore`
- `PetStore`

## Data boundaries

- `PersistenceService` owns persisted app snapshot
- `PetStore` owns persisted pet-specific state
- `AIStatsStore` merges indexed usage and live runtime state
- `AISessionStore` owns ephemeral hook-driven runtime/session live state only

## Current pet status

Implemented:

- egg selection and random egg hidden-species routing
- claim baseline XP
- custom naming on claim
- hatch threshold flow
- stage / evolution / Lv.100 FX overlays
- species persistence + inheritance history
- sleep detection
- bubble triggers
- daily damped pet stats cache

## Test map

- `RuntimeDriverTests`
- `AIRuntimeIngressHookEventTests`
- `AIRuntimeIngressSocketTests`
- `AISessionStoreTests`
- `PetFeatureTests`
- `scripts/dev/runtime-hook-smoke.py`
