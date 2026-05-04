defmodule SymphonyElixirWeb.Layouts do
  @moduledoc """
  Shared layouts for the observability dashboard.
  """

  use Phoenix.Component

  @spec root(map()) :: Phoenix.LiveView.Rendered.t()
  def root(assigns) do
    assigns = assign(assigns, :csrf_token, Plug.CSRFProtection.get_csrf_token())

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={@csrf_token} />
        <title>Symphony Observability</title>
        <script defer src="/vendor/phoenix_html/phoenix_html.js"></script>
        <script defer src="/vendor/phoenix/phoenix.js"></script>
        <script defer src="/vendor/phoenix_live_view/phoenix_live_view.js"></script>
        <script>
          window.addEventListener("DOMContentLoaded", function () {
            var csrfToken = document
              .querySelector("meta[name='csrf-token']")
              ?.getAttribute("content");

            if (!window.Phoenix || !window.LiveView) return;

            function taskCardSelector(taskId) {
              var escaped =
                window.CSS && window.CSS.escape
                  ? window.CSS.escape(taskId)
                  : taskId.replace(/["\\]/g, "\\$&");

              return '.ticket-card[data-task-id="' + escaped + '"]';
            }

            function focusTaskCard(taskId, attempt) {
              if (document.querySelector("#task-detail-backdrop") && attempt < 12) {
                window.setTimeout(function () {
                  focusTaskCard(taskId, attempt + 1);
                }, 80);
                return;
              }

              var board = document.getElementById("kanban-board");
              var card = (board || document).querySelector(taskCardSelector(taskId));

              if (!card && attempt < 12) {
                window.setTimeout(function () {
                  focusTaskCard(taskId, attempt + 1);
                }, 80);
                return;
              }

              if (!card) return;

              card.scrollIntoView({behavior: "smooth", block: "center", inline: "center"});
              window.focusedTaskTarget = {
                taskId: taskId,
                expiresAt: Date.now() + 4200
              };

              markFocusedTaskCard(card, taskId);
            }

            function markFocusedTaskCard(card, taskId) {
              card.classList.add("is-focus-target");

              if (!card.hasAttribute("tabindex")) {
                card.setAttribute("tabindex", "-1");
              }

              window.setTimeout(function () {
                card.focus({preventScroll: true});
              }, 260);

              if (card.focusTargetTimer) {
                window.clearTimeout(card.focusTargetTimer);
              }

              card.focusTargetTimer = window.setTimeout(function () {
                card.classList.remove("is-focus-target");
                if (window.focusedTaskTarget && window.focusedTaskTarget.taskId === taskId) {
                  window.focusedTaskTarget = null;
                }
              }, 3600);
            }

            function restoreFocusedTaskCard() {
              var target = window.focusedTaskTarget;
              if (!target || Date.now() > target.expiresAt) return;

              var board = document.getElementById("kanban-board");
              var card = (board || document).querySelector(taskCardSelector(target.taskId));
              if (!card) return;

              markFocusedTaskCard(card, target.taskId);
            }

            var Hooks = {};

            Hooks.ModalScrollLock = {
              mounted: function () {
                this.scrollY = window.scrollY || window.pageYOffset || 0;
                this.previousBodyPosition = document.body.style.position;
                this.previousBodyTop = document.body.style.top;
                this.previousBodyWidth = document.body.style.width;
                this.previousBodyOverflow = document.body.style.overflow;
                this.handleWheel = this.handleWheel.bind(this);
                this.handleBlockerFocusClick = this.handleBlockerFocusClick.bind(this);
                this.el.addEventListener("wheel", this.handleWheel, {passive: false});
                this.el.addEventListener("click", this.handleBlockerFocusClick, true);

                document.body.classList.add("has-modal-open");
                document.body.style.position = "fixed";
                document.body.style.top = "-" + this.scrollY + "px";
                document.body.style.width = "100%";
                document.body.style.overflow = "hidden";

                var modal = this.el.querySelector(".detail-modal, .create-modal");
                if (modal) modal.focus({preventScroll: true});
              },

              destroyed: function () {
                this.el.removeEventListener("wheel", this.handleWheel);
                this.el.removeEventListener("click", this.handleBlockerFocusClick, true);
                document.body.classList.remove("has-modal-open");
                document.body.style.position = this.previousBodyPosition || "";
                document.body.style.top = this.previousBodyTop || "";
                document.body.style.width = this.previousBodyWidth || "";
                document.body.style.overflow = this.previousBodyOverflow || "";
                window.scrollTo(0, this.scrollY || 0);
              },

              handleWheel: function (event) {
                if (!event.target.closest(".detail-modal, .create-modal")) {
                  event.preventDefault();
                }
              },

              handleBlockerFocusClick: function (event) {
                var trigger = event.target.closest("[data-focus-task-id]");
                if (!trigger || !this.el.contains(trigger)) return;

                var taskId = trigger.getAttribute("data-focus-task-id");
                if (!taskId) return;

                window.setTimeout(function () {
                  focusTaskCard(taskId, 0);
                }, 80);
              }
            };

            Hooks.KanbanBoard = {
              mounted: function () {
                this.handlePointerDown = this.handlePointerDown.bind(this);
                this.handlePointerMove = this.handlePointerMove.bind(this);
                this.handlePointerUp = this.handlePointerUp.bind(this);
                this.handleClick = this.handleClick.bind(this);
                this.handleFocusTaskCard = this.handleFocusTaskCard.bind(this);
                this.handleFocusTaskCardBrowserEvent = this.handleFocusTaskCardBrowserEvent.bind(this);
                this.el.addEventListener("pointerdown", this.handlePointerDown);
                this.el.addEventListener("click", this.handleClick, true);
                window.addEventListener("phx:focus-task-card", this.handleFocusTaskCardBrowserEvent);
                this.handleEvent("focus-task-card", this.handleFocusTaskCard);
              },

              destroyed: function () {
                this.teardownDrag(false);
                this.teardownPendingDrag();
                this.el.removeEventListener("pointerdown", this.handlePointerDown);
                this.el.removeEventListener("click", this.handleClick, true);
                window.removeEventListener("phx:focus-task-card", this.handleFocusTaskCardBrowserEvent);
              },

              updated: function () {
                this.restoreDragDomAfterPatch();
                restoreFocusedTaskCard();
              },

              handlePointerDown: function (event) {
                if (event.button !== 0) return;

                var card = event.target.closest(".ticket-card");
                if (!card || !this.el.contains(card)) return;
                if (event.target.closest("a, button, input, select, textarea")) return;

                var taskId = card.getAttribute("data-task-id");
                if (!taskId) return;

                this.pendingDrag = {
                  card: card,
                  taskId: taskId,
                  startX: event.clientX,
                  startY: event.clientY
                };

                document.addEventListener("pointermove", this.handlePointerMove, true);
                document.addEventListener("pointerup", this.handlePointerUp, true);
                document.addEventListener("pointercancel", this.handlePointerUp, true);
              },

              handleClick: function (event) {
                var card = event.target.closest(".ticket-card");
                if (!card) return;

                if (card.getAttribute("data-suppress-click") === "true") {
                  event.preventDefault();
                  event.stopPropagation();
                  card.removeAttribute("data-suppress-click");
                  return;
                }

                if (event.target.closest("a, button, input, select, textarea")) return;

                var taskId = card.getAttribute("data-task-id");
                if (!taskId) return;

                event.preventDefault();
                event.stopPropagation();
                this.pushEvent("open_task", {task_id: taskId});
              },

              handleFocusTaskCard: function (payload) {
                var taskId = payload && payload.task_id;
                if (!taskId) return;

                focusTaskCard(String(taskId), 0);
              },

              handleFocusTaskCardBrowserEvent: function (event) {
                this.handleFocusTaskCard(event.detail || {});
              },

              startDrag: function (event) {
                var pending = this.pendingDrag;
                if (!pending) return;

                var sourceCard = pending.card;
                var rect = sourceCard.getBoundingClientRect();
                var originParent = sourceCard.parentElement;
                var dragCard = sourceCard.cloneNode(true);
                var targetPlaceholder = this.makePlaceholder(rect, "is-target");

                this.markOriginCard(sourceCard, rect);

                this.drag = {
                  card: dragCard,
                  sourceCard: sourceCard,
                  taskId: pending.taskId,
                  originParent: originParent,
                  originState: sourceCard.getAttribute("data-state-name"),
                  originRect: {height: rect.height},
                  targetPlaceholder: targetPlaceholder,
                  offsetX: event.clientX - rect.left,
                  offsetY: event.clientY - rect.top,
                  lastClientX: event.clientX,
                  lastClientY: event.clientY,
                  currentDrop: null,
                  currentState: null
                };
                this.pendingDrag = null;

                dragCard.classList.remove("is-drag-origin-card", "drag-placeholder", "is-origin");
                dragCard.classList.add("is-drag-layer");
                dragCard.style.width = rect.width + "px";
                dragCard.style.left = rect.left + "px";
                dragCard.style.top = rect.top + "px";
                document.body.appendChild(dragCard);
                document.body.classList.add("is-kanban-dragging");

                this.moveCard(event);
                this.updateDropTarget(event);
              },

              handlePointerMove: function (event) {
                if (!this.drag && this.pendingDrag) {
                  var deltaX = event.clientX - this.pendingDrag.startX;
                  var deltaY = event.clientY - this.pendingDrag.startY;

                  if (Math.sqrt(deltaX * deltaX + deltaY * deltaY) < 6) return;

                  event.preventDefault();
                  this.startDrag(event);
                }

                if (!this.drag) return;

                event.preventDefault();
                this.moveCard(event);
                this.updateDropTarget(event);
              },

              handlePointerUp: function (event) {
                if (!this.drag && this.pendingDrag) {
                  this.teardownPendingDrag();
                  return;
                }

                if (!this.drag) return;

                event.preventDefault();

                var drag = this.drag;
                var dropState = drag.currentState;
                var beforeTaskId = this.taskIdAfterPlaceholder(drag.targetPlaceholder);
                var afterTaskId = this.taskIdBeforePlaceholder(drag.targetPlaceholder);

                if (dropState) {
                  drag.sourceCard.setAttribute("data-suppress-click", "true");
                  this.placeCardAtDropTarget();
                  this.pushEvent("move_task", {
                    task_id: drag.taskId,
                    target_state: dropState,
                    before_task_id: beforeTaskId || "",
                    after_task_id: afterTaskId || ""
                  });
                  this.teardownDrag(false);
                } else {
                  this.teardownDrag(true);
                }
              },

              moveCard: function (event) {
                var drag = this.drag;
                drag.lastClientX = event.clientX;
                drag.lastClientY = event.clientY;
                drag.card.style.left = event.clientX - drag.offsetX + "px";
                drag.card.style.top = event.clientY - drag.offsetY + "px";
              },

              updateDropTarget: function (event) {
                var drag = this.drag;
                this.clearDropTarget();

                var target = document.elementFromPoint(event.clientX, event.clientY);
                var drop = target && target.closest("[data-drop-state]");
                if (!drop || !this.el.contains(drop)) return;

                var stateName = drop.getAttribute("data-drop-state");
                if (!stateName) return;

                drop.classList.add("is-drop-active");
                drag.currentDrop = drop;
                drag.currentState = stateName;

                if (drop.getAttribute("data-hidden-drop") === "true") return;

                var list = drop.querySelector(".ticket-list");
                if (!list) return;

                var beforeCard = this.cardAfterPointer(list, event.clientY);
                var empty = list.querySelector(".empty-column");

                if (beforeCard) {
                  list.insertBefore(drag.targetPlaceholder, beforeCard);
                } else if (empty) {
                  list.insertBefore(drag.targetPlaceholder, empty);
                } else {
                  list.appendChild(drag.targetPlaceholder);
                }
              },

              clearDropTarget: function () {
                if (!this.drag) return;

                this.el.querySelectorAll(".is-drop-active").forEach(function (node) {
                  node.classList.remove("is-drop-active");
                });

                if (this.drag.targetPlaceholder.parentNode) {
                  this.drag.targetPlaceholder.parentNode.removeChild(this.drag.targetPlaceholder);
                }

                this.drag.currentDrop = null;
                this.drag.currentState = null;
              },

              cardAfterPointer: function (list, pointerY) {
                var cards = Array.prototype.slice.call(
                  list.querySelectorAll(".ticket-card:not(.is-drag-layer):not(.is-drag-origin-card)")
                );

                return cards.reduce(function (closest, child) {
                  var rect = child.getBoundingClientRect();
                  var offset = pointerY - rect.top - rect.height / 2;

                  if (offset < 0 && offset > closest.offset) {
                    return {offset: offset, element: child};
                  }

                  return closest;
                }, {offset: Number.NEGATIVE_INFINITY, element: null}).element;
              },

              taskIdAfterPlaceholder: function (placeholder) {
                var node = placeholder.nextElementSibling;

                while (node) {
                  if (node.classList.contains("ticket-card") && !node.classList.contains("is-drag-origin-card")) {
                    return node.getAttribute("data-task-id");
                  }
                  node = node.nextElementSibling;
                }

                return null;
              },

              taskIdBeforePlaceholder: function (placeholder) {
                var node = placeholder.previousElementSibling;

                while (node) {
                  if (node.classList.contains("ticket-card") && !node.classList.contains("is-drag-origin-card")) {
                    return node.getAttribute("data-task-id");
                  }
                  node = node.previousElementSibling;
                }

                return null;
              },

              placeCardAtDropTarget: function () {
                var drag = this.drag;

                if (drag.targetPlaceholder.parentNode) {
                  drag.targetPlaceholder.parentNode.insertBefore(drag.sourceCard, drag.targetPlaceholder);
                } else if (drag.originParent) {
                  drag.originParent.appendChild(drag.sourceCard);
                }
              },

              teardownDrag: function (restore) {
                if (!this.drag) return;

                var drag = this.drag;

                document.removeEventListener("pointermove", this.handlePointerMove, true);
                document.removeEventListener("pointerup", this.handlePointerUp, true);
                document.removeEventListener("pointercancel", this.handlePointerUp, true);
                document.body.classList.remove("is-kanban-dragging");

                this.el.querySelectorAll(".is-drop-active").forEach(function (node) {
                  node.classList.remove("is-drop-active");
                });

                this.unmarkOriginCard(drag.sourceCard);

                if (drag.targetPlaceholder.parentNode) {
                  drag.targetPlaceholder.parentNode.removeChild(drag.targetPlaceholder);
                }

                if (drag.card.parentNode) {
                  drag.card.parentNode.removeChild(drag.card);
                }

                this.drag = null;
                this.teardownPendingDrag();
              },

              teardownPendingDrag: function () {
                if (!this.pendingDrag) return;

                document.removeEventListener("pointermove", this.handlePointerMove, true);
                document.removeEventListener("pointerup", this.handlePointerUp, true);
                document.removeEventListener("pointercancel", this.handlePointerUp, true);
                this.pendingDrag = null;
              },

              makePlaceholder: function (rect, className) {
                var placeholder = document.createElement("div");
                placeholder.className = "drag-placeholder " + className;
                placeholder.style.height = rect.height + "px";
                return placeholder;
              },

              markOriginCard: function (card, rect) {
                card.classList.add("is-drag-origin-card", "drag-placeholder", "is-origin");
                card.style.height = rect.height + "px";
                card.setAttribute("aria-hidden", "true");
              },

              unmarkOriginCard: function (card) {
                if (!card) return;

                card.classList.remove("is-drag-origin-card", "drag-placeholder", "is-origin");
                card.style.removeProperty("height");
                card.removeAttribute("aria-hidden");
              },

              restoreDragDomAfterPatch: function () {
                if (!this.drag) return;

                var drag = this.drag;
                var selector = '.ticket-card[data-task-id="' + drag.taskId + '"]:not(.is-drag-layer)';
                var sourceCard = this.el.querySelector(selector);

                if (sourceCard) {
                  drag.sourceCard = sourceCard;
                  this.markOriginCard(sourceCard, drag.originRect);
                }

                if (drag.lastClientX != null && drag.lastClientY != null) {
                  this.updateDropTarget({clientX: drag.lastClientX, clientY: drag.lastClientY});
                }
              }
            };

            var liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
              hooks: Hooks,
              params: {_csrf_token: csrfToken}
            });

            liveSocket.connect();
            window.liveSocket = liveSocket;
          });
        </script>
        <link rel="stylesheet" href="/dashboard.css" />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <main class="app-shell">
      {@inner_content}
    </main>
    """
  end
end
