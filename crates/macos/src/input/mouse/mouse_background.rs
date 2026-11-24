use agent_desktop_core::{
    AdapterError, Deadline, ErrorCode, MouseButton, MouseEvent, MouseEventKind, OperationReport,
    Point, Rect,
};

const PRESS: &str = "AXPress";
const PRESS_SEARCH_DEPTH: usize = 4;

/// A plain click can go through the element under the point, which every window
/// accepts. Anything richer only exists as raw input.
fn can_press_element(event: &MouseEvent) -> bool {
    matches!(event.button, MouseButton::Left)
        && event.modifiers.is_empty()
        && matches!(event.kind, MouseEventKind::Click { count: 1 })
}

fn contains(rect: &Rect, point: &Point) -> bool {
    point.x >= rect.x
        && point.y >= rect.y
        && point.x < rect.x + rect.width
        && point.y < rect.y + rect.height
}

/// The window a click at the point is for, as its place in `windows`: the one `wanted` names, wherever it lies
/// among the app's others, or else the frontmost there. The flag says whether it is the frontmost at the point,
/// which is the window the element under the point belongs to. `windows` pairs each window's number with its
/// bounds in no stacking order; `front_to_back` numbers the windows that show, and one it leaves out lies behind.
fn target_window(
    windows: &[(i64, Rect)],
    front_to_back: &[i64],
    point: &Point,
    wanted: Option<i64>,
) -> Option<(usize, bool)> {
    let depth = |number: i64| {
        front_to_back
            .iter()
            .position(|shown| *shown == number)
            .unwrap_or(usize::MAX)
    };
    let here = || {
        windows
            .iter()
            .enumerate()
            .filter(|(_, (_, bounds))| contains(bounds, point))
    };
    let (top, _) = here().min_by_key(|(_, (number, _))| depth(*number))?;
    let target = match wanted {
        Some(wanted) => here().find(|(_, (number, _))| *number == wanted)?.0,
        None => top,
    };
    Some((target, target == top))
}

/// Window ids are `w-` and the window's number, as `list-windows` gives them.
fn window_number(id: &str) -> Result<i64, AdapterError> {
    id.strip_prefix("w-")
        .and_then(|number| number.parse::<i64>().ok())
        .filter(|number| *number > 0)
        .ok_or_else(|| {
            AdapterError::new(ErrorCode::InvalidArgs, format!("'{id}' is not a window id"))
                .with_suggestion("Pass an id from list-windows, such as w-1234")
        })
}

#[cfg(target_os = "macos")]
mod imp {
    use super::*;
    use crate::actions::ax_perform::{advertises_action, perform_observed_action};
    use crate::actions::chain::chain_delivery::DeliveryOutcome;
    use crate::system::window::cg_window::{
        WindowRecord, WindowRecordScope, showing_window_records, window_records_until,
    };
    use crate::tree::{AXElement, element_for_pid, properties::ax_ipc};
    use core_graphics::event::{CGEvent, CGEventType, CGMouseButton, EventField};
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
    use core_graphics::geometry::CGPoint;
    use foreign_types::ForeignType;
    use std::time::Instant;

    /// `CGEventField` 51: the window AppKit routes the event to. Without it the
    /// event reaches the app with no window, and no view ever sees it.
    const EVENT_WINDOW_NUMBER: u32 = 51;

    type SetWindowLocation = unsafe extern "C" fn(*mut std::ffi::c_void, CGPoint);

    /// Exported by CoreGraphics but not in its headers, so it is found at run time.
    /// AppKit hit-tests an event by this location, and a raw `CGEvent` otherwise
    /// carries the location of the real pointer's window.
    fn set_window_location() -> Option<SetWindowLocation> {
        let symbol =
            unsafe { libc::dlsym(libc::RTLD_DEFAULT, c"CGEventSetWindowLocation".as_ptr()) };
        (!symbol.is_null())
            .then(|| unsafe { std::mem::transmute::<*mut libc::c_void, SetWindowLocation>(symbol) })
    }

    pub(crate) fn background_click(
        pid: i32,
        window_id: Option<&str>,
        event: MouseEvent,
        deadline: Deadline,
    ) -> Result<OperationReport, AdapterError> {
        crate::input::mouse::validate_point(&event.point)?;
        let MouseEventKind::Click { count } = event.kind else {
            return Err(AdapterError::not_supported("background pointer gesture"));
        };
        let wanted = window_id.map(window_number).transpose()?;
        let showing = match wanted {
            Some(_) => Some(placed(&showing_window_records(pid)?)),
            None => None,
        };
        let on_top = showing.as_ref().is_none_or(|showing| {
            target_window(showing, &numbers(showing), &event.point, wanted)
                .is_some_and(|(_, frontmost)| frontmost)
        });
        if on_top && can_press_element(&event) && press_element_at(pid, &event.point, deadline)? {
            return Ok(OperationReport::background_click(&event, true));
        }
        let until = Instant::now() + deadline.remaining();
        let windows = window_records_until(until, WindowRecordScope::Pid(pid))?;
        let showing = match showing {
            Some(showing) => showing,
            None => placed(&showing_window_records(pid)?),
        };
        let (target, _) =
            target_window(&placed(&windows), &numbers(&showing), &event.point, wanted)
                .ok_or_else(|| no_window_at_point(wanted.is_some()))?;
        let window = &windows[target];
        let location = CGPoint::new(
            event.point.x - window.bounds.x,
            event.point.y - window.bounds.y,
        );
        post_click(pid, window.window_number, location, &event, count)?;
        Ok(OperationReport::background_click(&event, false))
    }

    fn placed(records: &[WindowRecord]) -> Vec<(i64, Rect)> {
        records
            .iter()
            .map(|record| (record.window_number, record.bounds))
            .collect()
    }

    fn numbers(placed: &[(i64, Rect)]) -> Vec<i64> {
        placed.iter().map(|(number, _)| *number).collect()
    }

    fn no_window_at_point(named: bool) -> AdapterError {
        if named {
            return AdapterError::new(
                ErrorCode::ElementNotFound,
                "That window of this app is not at that point",
            )
            .with_suggestion("Run list-windows for the window's bounds");
        }
        AdapterError::new(
            ErrorCode::ElementNotFound,
            "No window of this app is on screen at that point",
        )
        .with_suggestion("Run list-windows; a hidden or minimized app has no window to click")
    }

    fn press_element_at(pid: i32, point: &Point, deadline: Deadline) -> Result<bool, AdapterError> {
        let app = element_for_pid(pid);
        let (status, raw) =
            ax_ipc::element_at_position(&app, (point.x as f32, point.y as f32), deadline);
        if status != accessibility_sys::kAXErrorSuccess || raw.is_null() {
            return Ok(false);
        }
        let mut element = AXElement(raw);
        for _ in 0..PRESS_SEARCH_DEPTH {
            if advertises_action(&element, PRESS, deadline) == Some(true) {
                let outcome = perform_observed_action(&element, PRESS, deadline)?;
                return Ok(!matches!(outcome, DeliveryOutcome::NotDelivered));
            }
            match crate::actions::scroll_read::element(&element, "AXParent", deadline) {
                Ok(Some(parent)) => element = parent,
                _ => return Ok(false),
            }
        }
        Ok(false)
    }

    fn post_click(
        pid: i32,
        window: i64,
        location: CGPoint,
        event: &MouseEvent,
        count: u32,
    ) -> Result<(), AdapterError> {
        let set_location = set_window_location()
            .ok_or_else(|| AdapterError::not_supported("background pointer input on this macOS"))?;
        let (down, up, button) = match event.button {
            MouseButton::Left => (
                CGEventType::LeftMouseDown,
                CGEventType::LeftMouseUp,
                CGMouseButton::Left,
            ),
            MouseButton::Right => (
                CGEventType::RightMouseDown,
                CGEventType::RightMouseUp,
                CGMouseButton::Right,
            ),
            MouseButton::Middle => (
                CGEventType::OtherMouseDown,
                CGEventType::OtherMouseUp,
                CGMouseButton::Center,
            ),
        };
        let screen = CGPoint::new(event.point.x, event.point.y);
        let flags = crate::input::mouse::event_flags(&event.modifiers);
        for click in 1..=i64::from(count) {
            for (kind, pressure) in [(down, 1.0), (up, 0.0)] {
                let source = CGEventSource::new(CGEventSourceStateID::Private)
                    .map_err(|()| AdapterError::internal("CGEventSource::new failed"))?;
                let raw = CGEvent::new_mouse_event(source, kind, screen, button)
                    .map_err(|()| AdapterError::internal("CGEvent::new_mouse_event failed"))?;
                raw.set_flags(flags);
                raw.set_integer_value_field(EventField::MOUSE_EVENT_CLICK_STATE, click);
                raw.set_double_value_field(EventField::MOUSE_EVENT_PRESSURE, pressure);
                raw.set_integer_value_field(EVENT_WINDOW_NUMBER, window);
                raw.set_integer_value_field(
                    EventField::MOUSE_EVENT_WINDOW_UNDER_MOUSE_POINTER,
                    window,
                );
                raw.set_integer_value_field(
                    EventField::MOUSE_EVENT_WINDOW_UNDER_MOUSE_POINTER_THAT_CAN_HANDLE_THIS_EVENT,
                    window,
                );
                unsafe { set_location(raw.as_ptr().cast(), location) };
                raw.post_to_pid(pid);
            }
        }
        Ok(())
    }
}

#[cfg(not(target_os = "macos"))]
mod imp {
    use super::*;

    pub(crate) fn background_click(
        _pid: i32,
        _window_id: Option<&str>,
        _event: MouseEvent,
        _deadline: Deadline,
    ) -> Result<OperationReport, AdapterError> {
        Err(AdapterError::not_supported("background_click"))
    }
}

pub(crate) use imp::background_click;

#[cfg(test)]
mod tests {
    use super::*;

    fn click(button: MouseButton, count: u32) -> MouseEvent {
        MouseEvent {
            kind: MouseEventKind::Click { count },
            point: Point { x: 5.0, y: 5.0 },
            button,
            modifiers: Vec::new(),
        }
    }

    fn rect(x: f64, width: f64) -> Rect {
        Rect {
            x,
            y: 0.0,
            width,
            height: 10.0,
        }
    }

    #[test]
    fn only_a_plain_left_click_can_press_an_element() {
        assert!(can_press_element(&click(MouseButton::Left, 1)));
        assert!(!can_press_element(&click(MouseButton::Left, 2)));
        assert!(!can_press_element(&click(MouseButton::Right, 1)));
        let mut held = click(MouseButton::Left, 1);
        held.modifiers.push(agent_desktop_core::Modifier::Shift);
        assert!(!can_press_element(&held));
    }

    #[test]
    fn the_frontmost_window_at_the_point_wins_whatever_the_inventory_order() {
        let windows = [
            (1, rect(100.0, 10.0)),
            (2, rect(0.0, 10.0)),
            (3, rect(0.0, 20.0)),
        ];
        let point = Point { x: 5.0, y: 5.0 };
        assert_eq!(
            target_window(&windows, &[9, 3, 2, 1], &point, None),
            Some((2, true))
        );
        assert_eq!(
            target_window(&windows, &[2, 3], &point, None),
            Some((1, true))
        );
        let outside = Point { x: 50.0, y: 5.0 };
        assert_eq!(target_window(&windows, &[3, 2, 1], &outside, None), None);
    }

    #[test]
    fn a_named_window_gets_the_click_under_another_of_the_app() {
        let windows = [(2, rect(0.0, 10.0)), (3, rect(0.0, 20.0))];
        let point = Point { x: 5.0, y: 5.0 };
        assert_eq!(
            target_window(&windows, &[3, 2], &point, Some(2)),
            Some((0, false))
        );
        assert_eq!(
            target_window(&windows, &[3, 2], &point, Some(3)),
            Some((1, true))
        );
    }

    #[test]
    fn a_named_window_that_is_not_at_the_point_gets_no_click() {
        let windows = [(2, rect(0.0, 10.0)), (3, rect(100.0, 10.0))];
        let point = Point { x: 5.0, y: 5.0 };
        assert_eq!(target_window(&windows, &[3, 2], &point, Some(3)), None);
        assert_eq!(target_window(&windows, &[3, 2], &point, Some(7)), None);
    }

    #[test]
    fn a_window_that_does_not_show_lies_behind_those_that_do() {
        let windows = [(2, rect(0.0, 10.0)), (3, rect(0.0, 20.0))];
        let point = Point { x: 5.0, y: 5.0 };
        assert_eq!(target_window(&windows, &[3], &point, None), Some((1, true)));
        assert_eq!(target_window(&windows, &[], &point, None), Some((0, true)));
    }

    #[test]
    fn a_window_id_is_w_and_a_number() {
        assert_eq!(window_number("w-42").ok(), Some(42));
        for bad in ["42", "w-", "w-0", "w--3", "w-x"] {
            assert_eq!(
                window_number(bad).map_err(|error| error.code),
                Err(ErrorCode::InvalidArgs)
            );
        }
    }
}
