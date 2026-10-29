/// Width from which a page that can be a panel (Ask's answers) opens at the right edge with the
/// page behind it in view, instead of as a sheet.
///
/// The old calendar side panel route that lived here (a 200 ms ease-out slide with a shadow and
/// a border) is gone: nothing used it, and it moved on a tween rather than DenMotion's springs.
const double panelBreakpoint = 840;
