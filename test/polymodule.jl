@testset "PolyModule" begin
    m = Model()
    # Triggers the creation of polydata
    @test isnull(PolyJuMP.getpolydata(m).polymodule)
    @test_throws ErrorException PolyJuMP.getpolymodule(m)
    setpolymodule!(m, TestPolyModule)
    @test PolyJuMP.getpolymodule(m) == TestPolyModule
end
