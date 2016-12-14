(function ($, window) {
    $.fn.contextMenu = function (settings) {

        
        
        

        return this.each(function () {
            var $menu = $('<ul id="contextMenu" class="dropdown-menu" role="menu" style="display: none"/>')            
            $('body').append($menu)

            var e_cm = null;

            $.each(settings.menu, function(key, value) {
                
                var entry = $('<li><a tabindex="-1" href="#">'+value.name+'</a></li>')
                entry.click(function(e) {
                    e.data = e_cm;
                    value.callback(e)
                });
                $menu.append(entry)                              
            })

            // Open context menu
            var that = $(this)
            that.on("contextmenu", function (e) {
                e_cm = e;

                // return native menu if pressing control
                if (e.ctrlKey) return;
                
                //open menu                
                $menu.data("invokedOn", $(e.target))
                    .show()
                    .css({
                        position: "absolute",
                        left: getMenuPosition(e.clientX , 'width', 'scrollLeft'),
                        top: getMenuPosition(e.clientY , 'height', 'scrollTop')
                    })
                    .off('click')
                    .on('click', 'a', function (e) {
                        $menu.hide();
                    });
                
                return false;
            });

            //make sure menu closes on any click
            $('body').click(function () {
                $menu.hide();
            });
        });
        
        function getMenuPosition(mouse, direction, scrollDir) {
            var win = $(window)[direction](),
                scroll = $(window)[scrollDir](),
                menu = $(settings.menuSelector)[direction](),
                position = mouse + scroll;
                        
            // opening menu would pass the side of the page
            if (mouse + menu > win && menu < mouse) 
                position -= menu;
            
            return position;
        }    

    };
})(jQuery, window);