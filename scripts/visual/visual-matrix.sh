#!/usr/bin/env bash

# Shared defaults for reference capture and real-app comparison.
VISUAL_DEFAULT_SIZES="1180x760,860x560,1440x900"
VISUAL_DEFAULT_STATES="default,palette,find,preview,sidebar-hidden,source-editor,table-editor"

visual_state_to_app_label() {
    case "$1" in
        default) echo "baseline" ;;
        palette) echo "palette-open" ;;
        find) echo "find-open" ;;
        preview) echo "preview-on" ;;
        sidebar-hidden) echo "sidebar-hidden" ;;
        source-editor) echo "source-editing" ;;
        table-editor) echo "table-grid" ;;
        *) return 1 ;;
    esac
}
