initializeQueueActivityCharts = ->
  $('.js-queue-activity').each ->
    $activity = $(this)
    return if $activity.data('chart-initialized')

    series = $activity.data('series')
    return unless series? and series.length

    labels = (bucket.time for bucket in series)
    sent = (bucket.sent for bucket in series)
    softFail = (bucket.soft_fail for bucket in series)
    hardFail = (bucket.hard_fail for bucket in series)
    graph = $activity.find('.queueActivity__graph').get(0)
    return unless graph

    new Chartist.Line graph,
      labels: labels
      series: [sent, softFail, hardFail]
    ,
      fullWidth: true
      showArea: true
      lineSmooth: false
      axisY:
        onlyInteger: true
        offset: 42
      axisX:
        showGrid: false
        showLabel: false
        offset: 0
      height: '225px'
      chartPadding:
        top: 10
        right: 8
        bottom: 0
        left: 0

    $activity.data('chart-initialized', true)

formatQueueTime = (value) ->
  return '-' unless value
  new Date(value).toLocaleString()

formatQueueAge = (value) ->
  return '-' unless value
  seconds = Math.max(0, Math.floor((Date.now() - new Date(value).getTime()) / 1000))
  return 'less than a minute ago' if seconds < 60
  units = [
    [86400, 'day'],
    [3600, 'hour'],
    [60, 'minute']
  ]
  for unit in units
    if seconds >= unit[0]
      count = Math.floor(seconds / unit[0])
      return "#{count} #{unit[1]}#{if count == 1 then '' else 's'} ago"

refreshQueueCockpit = ($cockpit) ->
  return if document.hidden
  url = $cockpit.data('runtime-url')
  return unless url

  $.getJSON(url).done (payload) ->
    for key, value of payload.stats
      $cockpit.find("[data-queue-stat='#{key}']").text(Number(value).toLocaleString())

    for queue in payload.queues
      $row = $cockpit.find('tr[data-queue-name]').filter ->
        $(this).attr('data-queue-name') == queue.name
      continue unless $row.length
      $status = $row.find("[data-queue-value='status']")
      $status.removeClass('queueStatus--normal queueStatus--deferred queueStatus--backoff').addClass("queueStatus--#{queue.status}")
      $status.text(queue.status.charAt(0).toUpperCase() + queue.status.slice(1))
      $row.find("[data-queue-value='total']").text(Number(queue.total).toLocaleString())
      $row.find("[data-queue-value='ready']").text(Number(queue.ready).toLocaleString())
      $row.find("[data-queue-value='scheduled']").text(Number(queue.scheduled).toLocaleString())
      $row.find("[data-queue-value='locked']").text(Number(queue.locked).toLocaleString())
      $row.find("[data-queue-value='smtp']").text("#{queue.active_smtp_out}/#{queue.smtp_out_limit}")
      $row.find("[data-queue-value='next_attempt']").text(formatQueueTime(queue.next_attempt_at))
      $row.find("[data-queue-value='oldest']").text(formatQueueAge(queue.oldest_at))

    if payload.rest?
      $rest = $cockpit.find("tr[data-queue-name='Rest']")
      $rest.find("[data-queue-value='total']").text(Number(payload.rest.total).toLocaleString())
      $rest.find("[data-queue-value='ready']").text(Number(payload.rest.ready).toLocaleString())
      $rest.find("[data-queue-value='scheduled']").text(Number(payload.rest.scheduled).toLocaleString())
      $rest.find("[data-queue-value='next_attempt']").text(formatQueueTime(payload.rest.next_attempt_at))
      $rest.find("[data-queue-value='oldest']").text(formatQueueAge(payload.rest.oldest_at))

    $('.js-queue-snapshot').text(new Date(payload.snapshot_at).toLocaleString())

initializeQueueCockpit = ->
  initializeQueueActivityCharts()
  $('.js-queue-cockpit').each ->
    $cockpit = $(this)
    existingTimer = $cockpit.data('refresh-timer')
    clearInterval(existingTimer) if existingTimer
    timer = setInterval((-> refreshQueueCockpit($cockpit)), 30000)
    $cockpit.data('refresh-timer', timer)

$(document).on 'turbolinks:load', initializeQueueCockpit

$(document).on 'turbolinks:before-cache', ->
  $('.js-queue-cockpit').each ->
    timer = $(this).data('refresh-timer')
    clearInterval(timer) if timer

$(document).on 'visibilitychange', ->
  return if document.hidden
  $('.js-queue-cockpit').each -> refreshQueueCockpit($(this))

$(document).on 'click', '.js-copy-queue-transcript', ->
  target = document.getElementById($(this).data('target'))
  return unless target
  text = target.textContent
  if navigator.clipboard?
    navigator.clipboard.writeText(text)
  else
    selection = window.getSelection()
    range = document.createRange()
    range.selectNodeContents(target)
    selection.removeAllRanges()
    selection.addRange(range)
