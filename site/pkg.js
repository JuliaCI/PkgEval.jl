// handle collapsibles
var coll = document.getElementsByClassName("collapsible");
for (var i = 0; i < coll.length; i++) {
    coll[i].textContent = "▸ " + coll[i].textContent
    coll[i].addEventListener("click", function() {
        this.classList.toggle("active");
        var content = this.nextElementSibling;
        if (content.style.display === "block") {
            this.textContent = "▸" + this.textContent.substr(1)
            content.style.display = "none";
        } else {
            this.textContent = "▾" + this.textContent.substr(1)
            content.style.display = "block";
        }
    });
}
