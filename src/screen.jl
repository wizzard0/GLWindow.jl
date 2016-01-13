function openglerrorcallback(
        source::GLenum, typ::GLenum,
        id::GLuint, severity::GLenum,
        length::GLsizei, message::Ptr{GLchar},
        userParam::Ptr{Void}
    )
    errormessage = """
         ________________________________________________________________
        |
        | OpenGL Error!
        | source: $(GLENUM(source).name) :: type: $(GLENUM(typ).name)
        |  $(ascii(bytestring(message, length)))
        |________________________________________________________________
    """
    output = typ == GL_DEBUG_TYPE_ERROR ? error : info
    output(errormessage)
    nothing
end
global const _openglerrorcallback = cfunction(
    openglerrorcallback, Void,
    (GLenum, GLenum,GLuint, GLenum, GLsizei, Ptr{GLchar}, Ptr{Void})
)

#Screen constructor
function Screen(
        parent::Screen;
        name = gensym("Screen"),
        area 				      		 = parent.area,
        children::Vector{Screen}  		 = Screen[],
        inputs::Dict{Symbol, Any} 		 = parent.inputs,
        renderlist::Vector{RenderObject} = RenderObject[],

        hidden::Signal{Bool}   			 = parent.hidden,
        hasfocus::Signal{Bool} 			 = parent.hasfocus,

        nativewindow::Window 			 = parent.nativewindow,
        position 					     = Vec3f0(2),
        lookat 					     	 = Vec3f0(0),
        transparent                      = Signal(false)
    )

    pintersect = const_lift(intersect, const_lift(zeroposition, parent.area), area)

    #checks if mouse is inside screen and not inside any children
    relative_mousepos = const_lift(inputs[:mouseposition]) do mpos
        Point{2, Float64}(mpos[1]-pintersect.value.x, mpos[2]-pintersect.value.y)
    end
    insidescreen = const_lift(relative_mousepos) do mpos
        mpos[1]>=0 && mpos[2]>=0 && mpos[1] <= pintersect.value.w && mpos[2] <= pintersect.value.h && !any(screen->isinside(screen.area.value, mpos...), children)
    end
    # creates signals for the camera, which are only active if mouse is inside screen
    camera_input = merge(inputs, Dict(
        :mouseposition 	=> filterwhen(insidescreen, Vec(0.0, 0.0), relative_mousepos),
        :scroll_x 		=> filterwhen(insidescreen, 0.0, 			inputs[:scroll_x]),
        :scroll_y 		=> filterwhen(insidescreen, 0.0, 			inputs[:scroll_y]),
        :window_size 	=> area
    ))
    new_input = merge(inputs, Dict(
        :mouseinside 	=> insidescreen,
        :mouseposition 	=> relative_mousepos,
        :scroll_x 		=> inputs[:scroll_x],
        :scroll_y 		=> inputs[:scroll_y],
        :window_size 	=> area
    ))
    # creates cameras for the sceen with the new inputs
    ocamera = OrthographicPixelCamera(camera_input)
    pcamera = PerspectiveCamera(camera_input, position, lookat)
    screen  = Screen(name,
        area, parent, children, new_input,
        renderlist, hidden, hasfocus,
        Dict(:perspective=>pcamera, :orthographic_pixel=>ocamera),
        nativewindow,transparent
    )
    push!(parent.children, screen)
    screen
end

function scaling_factor(window::Vec{2, Int}, fb::Vec{2, Int})
    (window[1] == 0 || window[2] == 0) && return Vec{2, Float64}(1.0)
    Vec{2, Float64}(fb) ./ Vec{2, Float64}(window)
end

function corrected_coordinates(
        window_size::Signal{Vec{2,Int}},
        framebuffer_width::Signal{Vec{2,Int}},
        mouse_position::Vec{2,Float64}
    )
    s = scaling_factor(window_size.value, framebuffer_width.value)
    Vec(mouse_position[1], window_size.value[2] - mouse_position[2]) .* s
end

function standard_callbacks()
    Function[
        window_close,
        window_size,
        window_position,
        key_pressed,
        dropped_files,
        framebuffer_size,
        mouse_clicked,
        unicode_input,
        cursor_position,
        scroll,
        hasfocus,
        entered_window,
    ]
end

"""
Tries to create sensible context hints!
Taken from lessons learned at:
[GLFW](http://www.glfw.org/docs/latest/window.html)
"""
function standard_context_hints(major, minor)
    # this is spaar...Modern OpenGL !!!!
    major < 3 && error("OpenGL major needs to be at least 3.0. Given: $major")
    # core profile is only supported for OpenGL 3.2+ (and a must for OSX, so
    # for the sake of homogenity, we make it a must for all!)
    profile = minor >= 2 ? GLFW.OPENGL_CORE_PROFILE : GLFW.OPENGL_ANY_PROFILE
    [
        (GLFW.CONTEXT_VERSION_MAJOR, major),
        (GLFW.CONTEXT_VERSION_MINOR, minor),
        (GLFW.OPENGL_FORWARD_COMPAT, GL_TRUE),
        (GLFW.OPENGL_PROFILE, profile)
    ]
end
function SimpleRectangle{T}(position::Vec{2,T}, width::Vec{2,T})
    SimpleRectangle{T}(position..., width...)
end
function createwindow(
        name::AbstractString, w, h;
        debugging = false,
        major = 3,
        minor = 2,# this is what GLVisualize needs to offer all features
        windowhints = [(GLFW.SAMPLES, 4)],
        contexthints = standard_context_hints(major, minor),
        callbacks = standard_callbacks()
    )
    for (wh, ch) in zip(windowhints, contexthints)
        GLFW.WindowHint(wh...)
        GLFW.WindowHint(ch...)
    end

    @osx_only begin
        if debugging
            warn("OpenGL debug message callback not available on osx")
            debugging = false
        end
    end
    GLFW.WindowHint(GLFW.OPENGL_DEBUG_CONTEXT, Cint(debugging))

    window = GLFW.CreateWindow(w, h, utf8(name))
    GLFW.MakeContextCurrent(window)
    GLFW.ShowWindow(window)

    debugging && glDebugMessageCallbackARB(_openglerrorcallback, C_NULL)

    signal_dict = register_callbacks(window, callbacks)
    @materialize window_position, window_size, framebuffer_size, cursor_position, hasfocus = signal_dict
    window_area = map(SimpleRectangle,
        window_position,
        window_size
    )
    # seems to be necessary to set this as early as possible
    glViewport(0, 0, framebuffer_size.value...)

    mouseposition = const_lift(corrected_coordinates,
        Signal(window_size), Signal(framebuffer_size), cursor_position
    )

    buttonspressed = Int[]
    sizehint!(buttonspressed, 10) # make it less suspicable to growing/shrinking

    screen = Screen(symbol(name),
        window_area, Screen[], signal_dict,
        RenderObject[], Signal(false), hasfocus,
        Dict{Symbol, Any}(),
        window
    )
    screen
end

"""
Check if a Screen is opened.
"""
function Base.isopen(s::Screen)
    !GLFW.WindowShouldClose(s.nativewindow)
end

"""
Swap the framebuffers on the Screen.
"""
function swapbuffers(s::Screen)
    GLFW.SwapBuffers(s.nativewindow)
end

"""
Poll events on the screen which will propogate signals through react.
"""
function pollevents(::Screen)
    GLFW.PollEvents()
end
