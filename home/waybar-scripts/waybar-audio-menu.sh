#!/usr/bin/env bash

select_sink() {
    SINK_OPTIONS=$(pactl list short sinks | awk '{print $2 " (" $3 ") " $1}')
    SELECTED_SINK=$(echo -e "$SINK_OPTIONS" | fzf --prompt="Select Default Sink (Speaker): ")
    if [[ -n "$SELECTED_SINK" ]]; then
        SINK_ID=$(echo "$SELECTED_SINK" | awk '{print $NF}')
        pactl set-default-sink "$SINK_ID"
        notify-send "Waybar Audio" "Default Speaker set to: $(echo "$SELECTED_SINK" | sed 's/ (.*)//')"
    fi
}

select_source() {
    SOURCE_OPTIONS=$(pactl list short sources | awk '{print $2 " (" $3 ") " $1}')
    SELECTED_SOURCE=$(echo -e "$SOURCE_OPTIONS" | fzf --prompt="Select Default Source (Microphone): ")
    if [[ -n "$SELECTED_SOURCE" ]]; then
        SOURCE_ID=$(echo "$SELECTED_SOURCE" | awk '{print $NF}')
        pactl set-default-source "$SOURCE_ID"
        notify-send "Waybar Audio" "Default Microphone set to: $(echo "$SELECTED_SOURCE" | sed 's/ (.*)//')"
    fi
}

case "$1" in
    --sink)
        select_sink
        ;;
    --source)
        select_source
        ;;
    *)
        MENU_OPTIONS=("Select Default Speaker" "Select Default Microphone")
        SELECTED_OPTION=$(printf "%s
" "${MENU_OPTIONS[@]}" | fzf --prompt="Waybar Audio Menu: ")

        case "$SELECTED_OPTION" in
            "Select Default Speaker")
                select_sink
                ;;
            "Select Default Microphone")
                select_source
                ;;
        esac
        ;;
esac
