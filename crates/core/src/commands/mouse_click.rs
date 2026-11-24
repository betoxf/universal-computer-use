use crate::{
    AppError, Modifier, MouseButton, MouseEvent, MouseEventKind, Point,
    adapter::PlatformAdapter,
    commands::{
        operation_response::operation_response,
        point_resolve::{require_cursor_policy, require_pointer_capability},
    },
    context::CommandContext,
};
use serde_json::{Value, json};

pub struct MouseClickArgs {
    pub x: f64,
    pub y: f64,
    pub button: MouseButton,
    pub count: u32,
    pub modifiers: Vec<Modifier>,
    /// Sends the click to this app in the background instead of moving the pointer.
    pub app: Option<String>,
    /// With `app`: the window the click is for, also when another window of the app is over it.
    pub window_id: Option<String>,
}

pub fn execute(
    args: MouseClickArgs,
    adapter: &dyn PlatformAdapter,
    context: &CommandContext,
) -> Result<Value, AppError> {
    if args.app.is_some() {
        return background(args, adapter);
    }
    if args.window_id.is_some() {
        return Err(AppError::invalid_input_with_suggestion(
            "--window-id names the window for a click in the background",
            "Pass --app with it, or leave it out for a click with the pointer",
        ));
    }
    require_cursor_policy(context, "mouse-click")?;
    require_pointer_capability(adapter)?;
    crate::validate_mouse_click_count(args.count)?;
    let _cursor = crate::cursor_overlay::hold_cursor(context, crate::Deadline::standard()?);
    let lease = crate::commands::helpers::acquire_interaction_lease(adapter)?;
    let point = Point {
        x: args.x,
        y: args.y,
    };
    point.validate()?;
    let result = crate::cursor_overlay::dispatch_mouse_event_with_cursor(
        adapter,
        context,
        MouseEvent {
            kind: MouseEventKind::Click { count: args.count },
            point,
            button: args.button,
            modifiers: args.modifiers,
        },
        true,
        &lease,
    );
    operation_response(
        &result?,
        json!({ "x": args.x, "y": args.y, "count": args.count }),
    )
}

/// Moves nothing the user can feel, so it needs no `--headed`, and the overlay
/// stays out of it because that follows the real pointer.
fn background(args: MouseClickArgs, adapter: &dyn PlatformAdapter) -> Result<Value, AppError> {
    crate::validate_mouse_click_count(args.count)?;
    let lease = crate::commands::helpers::acquire_interaction_lease(adapter)?;
    let app =
        crate::system::app_lookup::resolve_app(args.app.as_deref(), adapter, lease.deadline())?;
    let point = Point {
        x: args.x,
        y: args.y,
    };
    point.validate()?;
    let event = MouseEvent {
        kind: MouseEventKind::Click { count: args.count },
        point,
        button: args.button,
        modifiers: args.modifiers,
    };
    let report = adapter.background_click(
        app.pid.get() as i32,
        args.window_id.as_deref(),
        event,
        &lease,
    )?;
    let mut target = json!({ "x": args.x, "y": args.y, "count": args.count, "app": app.name });
    if let Some(window_id) = args.window_id {
        target["window_id"] = json!(window_id);
    }
    operation_response(&report, target)
}

#[cfg(test)]
#[path = "mouse_click_tests.rs"]
mod tests;
