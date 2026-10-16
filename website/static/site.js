(function () {
  var b = document.querySelector('[data-burger]');
  if (!b) return;
  b.addEventListener('click', function () {
    var open = document.body.classList.toggle('menu');
    b.setAttribute('aria-expanded', open ? 'true' : 'false');
  });
})();
