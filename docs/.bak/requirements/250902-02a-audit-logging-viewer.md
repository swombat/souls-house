# Audit Logging Viewer

I want an audit log viewer in the admin interface - another sub-page under the site admin dropdown.

This viewer should also follow a master/detail pattern, but organised very differently. The heart of the view is a list of events, which will need to be paginated. Originally, set the page size to 10, since there are 13 events already in there, but later we will increase the page size to 50.

So we need an admin controller that's able to server paginated lists of audit logs, with a selected audit log detail view.

The list also needs to be filterable on the backend, with the following filters available as front-end dropdowns with type-ahead search:

- Filter by user
- Filter by account
- Filter by action
- Filter by object type
- Filter by date range

The list view should be in reverse chronological order, showing the most recent events at the top.

The detail view should show the all available details of the audit log record in a readable format, using the shadcn drawer component (installed).

I imagine the filters being above the list, with the list below them, and the drawer appears from below.

## Technical Notes

This should be using our synchronization framework to ensure that new events are added to the list as they happen, in real time. The specific events (selected or not) will not need to be synchronized since they are write only. This page does not need to reload once an event is selected, basically, though it should update the selection in the URL to make it easier for the user to share the link. The url should also include the filter and paging parameters, so that the user can share the link with specific filters applied.